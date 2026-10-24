"""Generate the synthetic insurance first-notice-of-loss (FNOL) dataset for the bring-your-own-weights LoRA root.

The reports are first notifications of a loss sent to an invented insurer, Harbourline Mutual. The insurer,
its brokers, its towns, its policy references (HLM-000000 pattern) and its police crime references
(CR-000000 pattern) are all fictional. The data contains no real customers, people, addresses, phone numbers
or email addresses. Each report is free text from a policyholder or a broker and covers motor, home, travel
and small-business lines, with varied phrasing, typos and lengths.

Every record carries four labels drawn from closed vocabularies: claim_type, severity, fraud_flag and
next_action. The labels follow fixed rules that can be read from the text, so an adapter has something real
to learn and an exact-match score per field is meaningful.

Label rules (a fact counts only if the report states it):
  claim_type   The kind of loss described: motor_collision, motor_theft, motor_glass, home_escape_of_water,
               home_fire, home_storm, home_theft, travel_medical, travel_baggage, liability_injury or
               business_interruption.
  severity     critical  if a person is taken to or admitted to hospital, or if a home fire leaves the
                         household displaced.
               otherwise the amount tier, raised by a floor:
                 amount tier   low under 1,000; medium 1,000 to 4,999; high 5,000 or more; an amount that
                               is not yet known counts as medium
                 floors        a minor injury gives at least medium; a displaced household gives at least
                               high; any home fire gives at least high
  fraud_flag   review if any of: the incident date is later than the date of the report; a theft claim (motor
               or home) has no police crime reference; a theft claim has cover that started 30 days or fewer
               before the incident and an amount of 5,000 or more. Otherwise none.
  next_action  the first rule that applies, in this order:
                 1. fraud_flag is review                              refer_to_special_investigations
                 2. cover is in doubt (renewal payment, exclusion)    refer_to_coverage_review
                 3. water still escaping, or a roof open to weather   arrange_emergency_repair
                 4. no photos, receipts or quotes yet                 request_documents
                 5. severity is low                                   fast_track_settlement
                 6. anything else                                     assign_adjuster

Output, written under --out (default ./.byow-work/dataset):
  train.jsonl     2000 records by default  Fireworks SFT training set (system, user and assistant messages)
  eval.jsonl       200 records by default  Fireworks SFT evaluation set, passed to the training job
  heldout.jsonl    200 records by default  never uploaded to Fireworks; used after deployment
  ood.jsonl         40 records by default  unrelated prompts (system and user messages only), a regression check
  manifest.json                            generator version, seed, counts, label distribution, SHA-256 per file

Held-out reports use frames, sentences and sign-offs that the training split never contains, so a held-out
score measures generalisation rather than memory. The same seed gives byte-identical JSONL files.
manifest.json differs between runs only in its creation time.

The script uses only the Python standard library. It prints an estimate of training tokens for the train
split (characters divided by four), so the cost can be checked against the live price list before a job
starts. The estimate is not a tokenizer count.

Usage:
  python make_dataset.py [--out DIR] [--seed N] [--train N] [--eval N] [--heldout N] [--ood N] [--epochs N]
  python make_dataset.py --self-test
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import random
import sys
from collections import Counter
from pathlib import Path

GENERATOR_VERSION = "2.0.0"
DEFAULT_SEED = 20261023
DEFAULT_OUT = Path(".byow-work/dataset")
DEFAULT_COUNTS = {"train": 2000, "eval": 200, "heldout": 200, "ood": 40}
DESCRIPTION = "Synthetic data; no real customer, person or address."
ORGANISATION = "Harbourline Mutual, a fictional insurer"

VOCABULARIES: dict[str, list[str]] = {
    "claim_type": [
        "motor_collision",
        "motor_theft",
        "motor_glass",
        "home_escape_of_water",
        "home_fire",
        "home_storm",
        "home_theft",
        "travel_medical",
        "travel_baggage",
        "liability_injury",
        "business_interruption",
    ],
    "severity": ["low", "medium", "high", "critical"],
    "fraud_flag": ["none", "review"],
    "next_action": [
        "fast_track_settlement",
        "assign_adjuster",
        "request_documents",
        "arrange_emergency_repair",
        "refer_to_special_investigations",
        "refer_to_coverage_review",
    ],
}

LABEL_RULES = [
    "severity critical: a person is taken to hospital, or a home fire displaces the household",
    "severity otherwise: amount tier (low under 1000, medium 1000 to 4999, high 5000 or more, unknown is medium), "
    "with floors: minor injury medium, displaced household high, home fire high",
    "fraud_flag review: incident date later than the report date; theft without a police crime reference; "
    "theft with cover started 30 days or fewer before the incident and an amount of 5000 or more",
    "next_action, first match: fraud review gives refer_to_special_investigations; cover in doubt gives "
    "refer_to_coverage_review; water still escaping or roof open gives arrange_emergency_repair; missing "
    "documents give request_documents; low severity gives fast_track_settlement; otherwise assign_adjuster",
]

THEFT_TYPES = ("motor_theft", "home_theft")
HIGH_VALUE = 5000
RECENT_DAYS = 30

TOWNS = [
    "Marrowby", "Tollbrook", "Eastwick Cross", "Pennhallow", "Saltmere", "Ashgrove Bay", "Dunmarrow",
    "Kelderby", "Wrenfield", "Thornquay", "Brackenmoor", "Quillham", "Stonevale", "Fennimore", "Lowrick Green",
    "Cobbleford", "Westerleigh Sands", "Yarrowmere", "Needham Fold", "Sallowby", "Orrinmouth", "Gantry Hill",
    "Pellwick", "Harcombe Ness",
]

# Tier weights (low, medium, high) for the claimed amount, by claim type.
TIER_WEIGHTS: dict[str, tuple[float, float, float]] = {
    "motor_collision": (0.15, 0.40, 0.45),
    "motor_theft": (0.0, 0.10, 0.90),
    "motor_glass": (0.80, 0.20, 0.0),
    "home_escape_of_water": (0.20, 0.45, 0.35),
    "home_fire": (0.0, 0.30, 0.70),
    "home_storm": (0.25, 0.45, 0.30),
    "home_theft": (0.35, 0.35, 0.30),
    "travel_medical": (0.20, 0.35, 0.45),
    "travel_baggage": (0.75, 0.25, 0.0),
    "liability_injury": (0.10, 0.40, 0.50),
    "business_interruption": (0.0, 0.40, 0.60),
}
AMOUNT_RANGES = {"low": (50, 990, 10), "medium": (1000, 4950, 50), "high": (5000, 40000, 250)}
INJURY_WEIGHTS = {  # none, minor, hospital
    "motor_collision": (0.60, 0.25, 0.15),
    "liability_injury": (0.0, 0.55, 0.45),
    "travel_medical": (0.0, 0.35, 0.65),
}
INJURY_NONE_RENDER_P = {"motor_collision": 0.8, "home_fire": 0.5}
DISPLACED_P = {"home_fire": 0.40, "home_escape_of_water": 0.20, "home_storm": 0.15}
ONGOING_P = {"home_escape_of_water": 0.50, "home_storm": 0.35}

# Training split wording. Frames and sentences here never appear in the held-out split.
TRAIN_PHRASES: dict = {
    "opener": [
        "Hello, I need to report a claim.",
        "Good morning, first notice of a loss below.",
        "Reporting an incident to Harbourline Mutual.",
        "Writing on behalf of a client to give notice of a loss.",
        "Quick report for you.",
    ],
    "filler": [
        "Please let me know what happens next.",
        "Thanks for your help.",
        "Please confirm you have received this.",
        "Sorry for the rush, it has been a stressful week.",
        "Let me know if you need more information.",
        "Apologies for any mistakes, typing this on my phone.",
    ],
    "closing": ["Thanks", "Regards", "Many thanks", "Best wishes"],
    "persona": ["Policyholder", "Calder Quay Brokers", "Tarn and Reed Brokers", "Insured"],
    "desc": {
        "motor_collision": [
            "The insured car was hit from behind at a roundabout and the rear is crushed.",
            "Two cars collided at a junction; the front wing and bumper are wrecked.",
            "A van pulled out and struck the driver's side of the insured vehicle.",
            "The car slid on a wet road and hit a wall.",
        ],
        "motor_theft": [
            "The insured car was stolen from the driveway overnight.",
            "Our van has been taken from outside the unit; it was parked and locked.",
            "The car was driven away from the car park while we were shopping.",
            "Vehicle theft: the hatchback is gone from where it was left.",
        ],
        "motor_glass": [
            "A stone chipped the windscreen and the crack is spreading.",
            "The windscreen cracked across the driver's side on the bypass.",
            "The rear window of the car was broken by flying gravel.",
            "A side window on the van shattered after a stone hit it.",
        ],
        "home_escape_of_water": [
            "A pipe burst under the kitchen sink and water has soaked the floor.",
            "The washing machine hose split and flooded the utility room.",
            "Water is coming through the bathroom ceiling from a failed pipe.",
            "A radiator pipe failed and water has run into the lounge.",
        ],
        "home_fire": [
            "A fire started in the kitchen from a chip pan and spread to the units.",
            "An electrical fault caused a fire in the living room.",
            "Fire broke out in the garage and damaged the roof and walls.",
            "A chimney fire spread into the loft.",
        ],
        "home_storm": [
            "Strong winds blew tiles off the roof.",
            "A storm brought down a fence and damaged the garage door.",
            "A fallen tree from the gale hit the conservatory.",
            "Heavy rain and wind damaged the chimney and gutters.",
        ],
        "home_theft": [
            "Burglars broke in through the back door and took electronics and jewellery.",
            "The house was burgled while we were away and the bedroom was ransacked.",
            "A break-in at the property; a laptop, a television and cash were taken.",
            "Thieves forced a window and stole tools from the shed.",
        ],
        "travel_medical": [
            "The policyholder fell ill on holiday abroad and needed a doctor.",
            "A traveller broke an ankle while hiking on a trip overseas.",
            "Food poisoning on a package holiday meant treatment at a local clinic.",
            "Injured in a scooter fall during a trip abroad.",
        ],
        "travel_baggage": [
            "The suitcase did not arrive at the airport after the flight.",
            "Luggage was lost on the return journey and has not been found.",
            "A bag was damaged by the airline and the zip has broken.",
            "Checked baggage was delayed and the contents have gone missing.",
        ],
        "liability_injury": [
            "A visitor slipped on a wet floor at the premises and was hurt.",
            "A delivery driver fell over a loose paving slab outside the property.",
            "A customer claims they were injured by a falling shelf in the shop.",
            "A neighbour's child was hurt by a branch falling from the insured tree.",
        ],
        "business_interruption": [
            "The shop has had to close after the incident and trade has stopped.",
            "The workshop cannot operate because of the damage and income is lost.",
            "The cafe closed for repairs and has no takings.",
            "The business is shut while the unit is made safe, with staff unable to work.",
        ],
    },
    "when": [
        "It happened on {inc}.",
        "The incident date was {inc}.",
        "This occurred on {inc}.",
        "Date of loss: {inc}.",
    ],
    "start": [
        "Cover began on {start}.",
        "The policy started on {start}.",
        "Policy inception date: {start}.",
    ],
    "amount": [
        "The estimated cost is {amt}.",
        "Repair quote: {amt}.",
        "We expect the claim to be about {amt}.",
        "Estimated value of the loss, {amt}.",
    ],
    "missing": [
        "No photos, receipts or quotes yet.",
        "We do not have photos or an estimate yet; documents to follow.",
        "Photos and invoices are not available yet.",
    ],
    "injury_hospital": [
        "The person was taken to hospital and admitted overnight.",
        "An ambulance took the injured person to hospital, where they were admitted.",
        "They are in hospital after surgery.",
    ],
    "injury_minor": [
        "A minor injury only; seen at the surgery and sent home.",
        "Only bruising, treated at a walk-in clinic and sent home.",
    ],
    "injury_none": ["Nobody was hurt.", "No injuries."],
    "displaced_yes": [
        "The household cannot stay in the property and has moved out.",
        "The family has had to leave the house and needs somewhere to stay.",
    ],
    "displaced_no": [
        "The household is still living in the property.",
        "The family is staying put in the house.",
    ],
    "ongoing_water_yes": [
        "Water is still escaping and the leak has not been stopped.",
        "The stopcock will not turn off and the water keeps running.",
    ],
    "ongoing_water_no": ["The water has been turned off at the mains.", "The leak has been stopped."],
    "ongoing_roof_yes": [
        "The roof is open to the weather and rain is getting in.",
        "There is a hole in the roof and it needs covering urgently.",
    ],
    "ongoing_roof_no": ["The property is still weathertight."],
    "police_yes": [
        "Reported to the police; crime reference {crime}.",
        "Police informed, reference {crime}.",
        "The police gave crime reference {crime}.",
    ],
    "police_no": [
        "It has not been reported to the police.",
        "No police report has been made.",
        "We have not told the police.",
    ],
    "coverage": [
        "It is unclear whether the policy covers this, as the renewal payment may have failed.",
        "Cover is in doubt because an exclusion for gradual damage may apply.",
        "The insured is not sure the policy covers this kind of event.",
    ],
}

TRAIN_TEMPLATES = [
    "Subject: First notice of loss – {policy}\nReceived: {notified}\nLocation: {place}\n\n{body}\n\n{signoff}",
    "Web form | Policy {policy} | Reported {notified} | {place}\n{body}\n{signoff}",
    "Hi Harbourline team,\n\n{body}\n\nPolicy number: {policy}. Writing on {notified} from {place}.\n{signoff}",
    "Phone note, {notified}. Caller from {place}, policy {policy}. {body}",
    "{body} Policy {policy}. Date of this report: {notified}. Town: {place}.",
    "Claim notification\nPolicy: {policy}\nDate notified: {notified}\n{body}\nLocal area: {place}",
]

# Held-out wording. Different frames, sentences and sign-offs from the training split.
HELD_PHRASES: dict = {
    "opener": [
        "Dear claims team, notifying you of a loss.",
        "Hi, please open a claim for the following.",
        "Broker notification of an insured loss.",
    ],
    "filler": [
        "Grateful for a quick reply.",
        "Do tell me what you need from me.",
        "Happy to provide more on request.",
    ],
    "closing": ["Kind regards", "Cheers", "With thanks"],
    "persona": ["Account holder", "Fenmoor Broking", "Customer"],
    "desc": {
        "motor_collision": [
            "Rear-ended while queuing in traffic; boot and tail lights smashed.",
            "Collision with another vehicle on a slip road, both cars damaged.",
        ],
        "motor_theft": [
            "Came out this morning and the vehicle had been stolen.",
            "Car taken from the street overnight, with the keys still in the house.",
        ],
        "motor_glass": [
            "Chip in the front screen from a lorry on the dual carriageway, now cracking.",
            "Wing mirror glass and the side window broken by road debris.",
        ],
        "home_escape_of_water": [
            "Burst pipe in the loft, ceilings in two rooms are wet.",
            "The water tank overflowed and damaged the hall carpet.",
        ],
        "home_fire": [
            "Smoke and flames from the oven area; the fire brigade attended and put it out.",
            "The tumble dryer caught fire and scorched the room.",
        ],
        "home_storm": [
            "Gale damage: slates lost and the shed roof lifted.",
            "Storm flattened part of the boundary wall and broke a window.",
        ],
        "home_theft": [
            "Someone got into the house overnight and took valuables.",
            "Burglary: back door forced, drawers emptied.",
        ],
        "travel_medical": [
            "Taken ill during a city break overseas and treated locally.",
            "Medical emergency while on holiday; emergency treatment abroad.",
        ],
        "travel_baggage": [
            "Our hold bag never came off the plane.",
            "Case arrived crushed with items missing.",
        ],
        "liability_injury": [
            "A third party says they tripped on the stairs and were injured.",
            "A passer-by was hit by a falling sign and is making a claim.",
        ],
        "business_interruption": [
            "Trading has stopped at the premises following the loss.",
            "Our small firm is closed and revenue has dried up.",
        ],
    },
    "when": ["Loss date {inc}.", "It took place on {inc}."],
    "start": ["Cover has been in force since {start}.", "The policy incepted on {start}."],
    "amount": ["Estimate so far is {amt}.", "Likely cost around {amt}."],
    "missing": [
        "Supporting papers still to come, nothing to attach.",
        "Nothing to attach at this stage: no photos, no quote.",
    ],
    "injury_hospital": ["Hospital admission was needed after the accident.", "Treated as an inpatient in hospital."],
    "injury_minor": ["Slight injury, a check at the pharmacy, nothing more.", "Minor cuts, patched up at home."],
    "injury_none": ["Thankfully no one was injured."],
    "displaced_yes": ["Nobody can live in the home at the moment; they are in temporary lodging."],
    "displaced_no": ["Occupants remain at home."],
    "ongoing_water_yes": ["The leak is ongoing; it has not been shut off."],
    "ongoing_water_no": ["Supply isolated, no further leakage."],
    "ongoing_roof_yes": ["There is a gap in the roof and rain is coming through."],
    "ongoing_roof_no": ["The building is dry and secure."],
    "police_yes": ["Logged with the police under {crime}.", "Police report made, ref {crime}."],
    "police_no": ["Police not contacted so far.", "Nothing reported to the police yet."],
    "coverage": [
        "There is a question over cover; the premium may have lapsed.",
        "Possible policy exclusion; cover needs checking.",
    ],
}

HELD_TEMPLATES = [
    "FNOL via broker portal – ref {policy} – lodged {notified} – {place}\n{body}",
    "Dear claims team, I am reporting a loss near {place}. My policy is {policy} and today is {notified}. {body}\n{signoff}",
    "[{notified}] inbound message re {policy} ({place}): {body}",
]

OOD_PROMPTS = [
    "Write a haiku about pine forests.",
    "What is the capital of Portugal?",
    "Give me a recipe for lentil soup.",
    "Translate good morning into German.",
    "Explain how a sourdough starter works.",
    "Summarise the rules of chess in three bullet points.",
    "Write a limerick about a cat who likes trains.",
    "Suggest three names for a bakery.",
    "How many legs does a spider have?",
    "Write a short product description for a bamboo toothbrush.",
    "Plan a three-day walking route in the Scottish Highlands.",
    "Explain the difference between a noun and a verb.",
    "What is the boiling point of water at sea level in Fahrenheit?",
    "Draft a polite email declining a meeting invitation.",
    "List five houseplants that tolerate low light.",
    "Convert 25 kilometres into miles.",
    "Write a two-line poem about autumn leaves.",
    "What were the main causes of the French Revolution?",
    "Describe a simple way to sort a list of numbers.",
    "Which planet has the most moons?",
    "Give me three tips for learning to juggle.",
    "What is the chemical symbol for gold?",
    "Write a thank-you note to a neighbour who fed the cat.",
    "Explain what a prime number is to a ten-year-old.",
    "Suggest a playlist theme for a long train journey.",
    "How do I convert a fraction to a percentage?",
    "Describe the water cycle in four sentences.",
    "What is a good stretching routine for the morning?",
    "Write a slogan for a second-hand bookshop.",
    "How long should I roast a chicken that weighs two kilograms?",
    "Name four types of cloud and say what each looks like.",
    "Write a riddle about a clock.",
    "Explain the offside rule in football.",
    "Suggest a name for a pet tortoise.",
    "What is the tallest mountain in Africa?",
    "Write a short bedtime story about a lighthouse keeper.",
    "List three differences between a frog and a toad.",
    "How do I remove a tea stain from a white shirt?",
    "Give me a mnemonic for the order of the planets.",
    "Explain why the sky looks blue during the day.",
]

MONTHS = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]
DATE_STYLES = ("iso", "long", "uk", "short")


def system_prompt() -> str:
    allowed = "; ".join(f"{field}: {', '.join(values)}" for field, values in VOCABULARIES.items())
    return (
        "You triage insurance first-notice-of-loss reports for Harbourline Mutual, a fictional insurer. "
        "Reply with one JSON object that has the keys claim_type, severity, fraud_flag and next_action. "
        "Allowed values: " + allowed + "."
    )


def label_facts(facts: dict) -> dict[str, str]:
    """Apply the documented rules to a fact set. This is the single source of the labels."""
    theft = facts["claim_type"] in THEFT_TYPES
    amount = facts["amount"]
    high_value = amount is not None and amount >= HIGH_VALUE

    review = (
        facts["inconsistent"]
        or (theft and not facts["police"])
        or (theft and facts["recent"] and high_value)
    )

    if facts["injury"] == "hospital" or (facts["claim_type"] == "home_fire" and facts["displaced"]):
        severity = "critical"
    else:
        if amount is None:
            rank = 1
        elif amount < 1000:
            rank = 0
        elif amount < HIGH_VALUE:
            rank = 1
        else:
            rank = 2
        if facts["injury"] == "minor":
            rank = max(rank, 1)
        if facts["displaced"] or facts["claim_type"] == "home_fire":
            rank = max(rank, 2)
        severity = ["low", "medium", "high"][rank]

    if review:
        action = "refer_to_special_investigations"
    elif facts["coverage_doubt"]:
        action = "refer_to_coverage_review"
    elif facts["ongoing"]:
        action = "arrange_emergency_repair"
    elif facts["missing"]:
        action = "request_documents"
    elif severity == "low":
        action = "fast_track_settlement"
    else:
        action = "assign_adjuster"

    return {
        "claim_type": facts["claim_type"],
        "fraud_flag": "review" if review else "none",
        "next_action": action,
        "severity": severity,
    }


def draw_facts(rng: random.Random) -> dict:
    claim_type = rng.choice(VOCABULARIES["claim_type"])
    theft = claim_type in THEFT_TYPES
    missing = rng.random() < 0.12
    tier = rng.choices(["low", "medium", "high"], weights=TIER_WEIGHTS[claim_type])[0]
    low, high, step = AMOUNT_RANGES[tier]
    amount = None if missing else rng.randint(low // step, high // step) * step
    if claim_type in INJURY_WEIGHTS:
        injury = rng.choices(["none", "minor", "hospital"], weights=INJURY_WEIGHTS[claim_type])[0]
    else:
        injury = "none"
    displaced = rng.random() < DISPLACED_P.get(claim_type, 0.0)
    ongoing = rng.random() < ONGOING_P.get(claim_type, 0.0)
    police = (rng.random() < 0.75) if theft else None
    start_stated = theft or rng.random() < 0.4
    recent = start_stated and rng.random() < (0.20 if theft else 0.15)
    return {
        "claim_type": claim_type,
        "amount": amount,
        "injury": injury,
        "displaced": displaced,
        "ongoing": ongoing,
        "police": police,
        "start_stated": start_stated,
        "recent": recent,
        "inconsistent": rng.random() < 0.06,
        "missing": missing,
        "coverage_doubt": rng.random() < 0.08,
    }


def format_date(day: dt.date, style: str) -> str:
    if style == "iso":
        return day.isoformat()
    if style == "long":
        return f"{day.day} {MONTHS[day.month - 1]} {day.year}"
    if style == "uk":
        return f"{day.day:02d}/{day.month:02d}/{day.year}"
    return f"{day.day} {MONTHS[day.month - 1][:3]} {day.year}"


def add_typos(rng: random.Random, text: str, rate: float = 0.05) -> str:
    words = text.split(" ")
    for index, word in enumerate(words):
        core = word.strip(".,;:!?")
        roll = rng.random()
        if len(core) >= 6 and core.isalpha() and roll < rate:
            cut = rng.randint(1, len(core) - 3)
            swapped = core[:cut] + core[cut + 1] + core[cut] + core[cut + 2:]
            words[index] = word.replace(core, swapped, 1)
    return " ".join(words)


def capitalise(sentence: str) -> str:
    return sentence[:1].upper() + sentence[1:]


def report_text(rng: random.Random, family: str, facts: dict) -> str:
    phrases = HELD_PHRASES if family == "heldout" else TRAIN_PHRASES
    templates = HELD_TEMPLATES if family == "heldout" else TRAIN_TEMPLATES
    style = rng.choice(DATE_STYLES)

    notified = dt.date(2026, 2, 1) + dt.timedelta(days=rng.randint(0, 250))
    if facts["inconsistent"]:
        incident = notified + dt.timedelta(days=rng.randint(1, 14))
    else:
        incident = notified - dt.timedelta(days=rng.randint(0, 10))
    gap = rng.randint(3, 28) if facts["recent"] else rng.randint(150, 1800)
    start = incident - dt.timedelta(days=gap)
    policy = f"HLM-{rng.randint(0, 99999):06d}"
    crime = f"CR-{rng.randint(0, 99999):06d}"
    place = rng.choice(TOWNS)

    # Narrative sentences may carry typos and lower case; fact sentences stay clean.
    narrative = [rng.choice(phrases["desc"][facts["claim_type"]])]
    if rng.random() < 0.7:
        narrative.insert(0, rng.choice(phrases["opener"]))
    fillers = [rng.choice(phrases["filler"]) for _ in range(rng.choice((0, 0, 1, 1, 2)))]
    lower = rng.random() < 0.12
    typos = rng.random() < 0.35

    def tidy(sentence: str) -> str:
        if typos:
            sentence = add_typos(rng, sentence)
        return sentence.lower() if lower else sentence

    narrative = [tidy(s) for s in narrative]
    fillers = [tidy(s) for s in fillers]

    claim_type = facts["claim_type"]
    fact_sentences = [rng.choice(phrases["when"]).format(inc=format_date(incident, style))]
    if facts["start_stated"]:
        fact_sentences.append(rng.choice(phrases["start"]).format(start=format_date(start, style)))
    if facts["amount"] is not None:
        fact_sentences.append(rng.choice(phrases["amount"]).format(amt=f"£{facts['amount']:,}"))
    else:
        fact_sentences.append(rng.choice(phrases["missing"]))
    if claim_type in INJURY_WEIGHTS:
        fact_sentences.append(rng.choice(phrases["injury_" + facts["injury"]]))
    elif facts["injury"] == "none" and rng.random() < INJURY_NONE_RENDER_P.get(claim_type, 0.0):
        fact_sentences.append(rng.choice(phrases["injury_none"]))
    if claim_type in DISPLACED_P and (facts["displaced"] or rng.random() < 0.85):
        fact_sentences.append(rng.choice(phrases["displaced_yes" if facts["displaced"] else "displaced_no"]))
    if claim_type in ONGOING_P and (facts["ongoing"] or rng.random() < 0.85):
        kind = "water" if claim_type == "home_escape_of_water" else "roof"
        state = "yes" if facts["ongoing"] else "no"
        fact_sentences.append(rng.choice(phrases[f"ongoing_{kind}_{state}"]))
    if facts["police"]:
        fact_sentences.append(rng.choice(phrases["police_yes"]).format(crime=crime))
    elif facts["police"] is False and rng.random() < 0.75:
        fact_sentences.append(rng.choice(phrases["police_no"]))
    if facts["coverage_doubt"]:
        fact_sentences.append(rng.choice(phrases["coverage"]))
    rng.shuffle(fact_sentences)

    body_parts = narrative + fact_sentences + fillers
    body = " ".join(capitalise(s) if not lower else s for s in body_parts)
    signoff = f"{rng.choice(phrases['closing'])}\n{rng.choice(phrases['persona'])}"
    return rng.choice(templates).format(
        policy=policy,
        notified=format_date(notified, style),
        place=place,
        body=body,
        signoff=signoff,
    )


def labelled_record(text: str, labels: dict[str, str]) -> dict:
    assistant = json.dumps(labels, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {
        "messages": [
            {"role": "system", "content": system_prompt()},
            {"role": "user", "content": text},
            {"role": "assistant", "content": assistant},
        ]
    }


def build_split(name: str, count: int, seed: int, seen: set[str]) -> list[dict]:
    rng = random.Random(f"{seed}:{name}")
    records: list[dict] = []
    if name == "ood":
        prompts = OOD_PROMPTS[:]
        rng.shuffle(prompts)
        for index in range(count):
            base = prompts[index % len(prompts)]
            text = base if index < len(prompts) else f"{base} (variant {index // len(prompts) + 1})"
            records.append({"messages": [
                {"role": "system", "content": system_prompt()},
                {"role": "user", "content": text},
            ]})
        return records
    family = "heldout" if name == "heldout" else "train"
    while len(records) < count:
        facts = draw_facts(rng)
        text = report_text(rng, family, facts)
        if text in seen:
            continue
        seen.add(text)
        records.append(labelled_record(text, label_facts(facts)))
    return records


def serialise(records: list[dict]) -> bytes:
    lines = [json.dumps(r, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for r in records]
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_splits(seed: int, counts: dict[str, int]) -> dict[str, list[dict]]:
    seen: set[str] = set()
    return {name: build_split(name, counts[name], seed, seen) for name in ("train", "eval", "heldout", "ood")}


def content_characters(records: list[dict]) -> int:
    return sum(len(m["content"]) for r in records for m in r["messages"])


def label_distribution(records: list[dict]) -> dict[str, dict[str, int]]:
    counts: dict[str, Counter] = {field: Counter() for field in VOCABULARIES}
    for record in records:
        labels = json.loads(record["messages"][-1]["content"])
        for field in VOCABULARIES:
            counts[field][labels[field]] += 1
    return {field: {value: counts[field].get(value, 0) for value in VOCABULARIES[field]} for field in VOCABULARIES}


def is_labelled(records: list[dict]) -> bool:
    return bool(records) and records[0]["messages"][-1]["role"] == "assistant"


def flatten(node) -> set[str]:
    if isinstance(node, str):
        return {node}
    if isinstance(node, dict):
        return set().union(*(flatten(v) for v in node.values()))
    return set().union(*(flatten(v) for v in node))


def self_test() -> int:
    checks: list[dict] = []

    def record(name: str, ok: bool, detail: str = "") -> None:
        checks.append({"check": name, "passed": ok, "detail": detail})

    small = {"train": 40, "eval": 10, "heldout": 10, "ood": 5}
    first = build_splits(DEFAULT_SEED, small)
    second = build_splits(DEFAULT_SEED, small)
    different = build_splits(DEFAULT_SEED + 1, small)
    same_bytes = all(serialise(first[n]) == serialise(second[n]) for n in first)
    record("same seed gives identical bytes", same_bytes)
    record("different seed changes the train split", serialise(first["train"]) != serialise(different["train"]))

    larger = build_splits(DEFAULT_SEED, {"train": 600, "eval": 50, "heldout": 50, "ood": 5})
    allowed_ok = True
    for name in ("train", "eval", "heldout"):
        for rec in larger[name]:
            roles = [m["role"] for m in rec["messages"]]
            if roles != ["system", "user", "assistant"]:
                allowed_ok = False
            labels = json.loads(rec["messages"][-1]["content"])
            if set(labels) != set(VOCABULARIES):
                allowed_ok = False
            for field, values in VOCABULARIES.items():
                if labels.get(field) not in values:
                    allowed_ok = False
    record("every label is in its vocabulary and every record has three roles", allowed_ok)

    seen_values = label_distribution(larger["train"])
    missing_values = [f"{f}:{v}" for f, d in seen_values.items() for v, n in d.items() if n == 0]
    record("every vocabulary value occurs in a 600-record train sample", not missing_values, ", ".join(missing_values))

    ood_ok = all([m["role"] for m in r["messages"]] == ["system", "user"] for r in first["ood"])
    record("ood records have no assistant message", ood_ok)

    train_texts = {m["content"] for r in first["train"] + first["eval"] for m in r["messages"] if m["role"] == "user"}
    held_texts = {m["content"] for r in first["heldout"] for m in r["messages"] if m["role"] == "user"}
    record("held-out reports share no text with train or eval", not (train_texts & held_texts))

    template_overlap = set(TRAIN_TEMPLATES) & set(HELD_TEMPLATES)
    record("held-out templates differ from training templates", not template_overlap)
    phrase_overlap = flatten(TRAIN_PHRASES) & flatten(HELD_PHRASES)
    record("held-out sentences differ from training sentences", not phrase_overlap, "; ".join(sorted(phrase_overlap)))

    counts_ok = all(len(first[n]) == small[n] for n in small)
    record("split sizes match the requested counts", counts_ok)

    base = {"claim_type": "motor_collision", "amount": 2000, "injury": "none", "displaced": False, "ongoing": False,
            "police": None, "recent": False, "inconsistent": False, "missing": False, "coverage_doubt": False}

    def labels_for(**changes) -> dict[str, str]:
        return label_facts({**base, **changes})

    rule_cases = [
        ("home fire with displaced household is critical", labels_for(claim_type="home_fire", displaced=True)["severity"], "critical"),
        ("hospital injury is critical", labels_for(injury="hospital")["severity"], "critical"),
        ("small glass claim is fast-tracked", labels_for(claim_type="motor_glass", amount=300)["next_action"], "fast_track_settlement"),
        ("theft without a crime reference is a fraud review", labels_for(claim_type="home_theft", police=False)["fraud_flag"], "review"),
        ("recent cover plus high-value theft goes to investigations", labels_for(claim_type="motor_theft", police=True, recent=True, amount=9000)["next_action"], "refer_to_special_investigations"),
        ("recent cover plus low-value theft is not flagged", labels_for(claim_type="home_theft", police=True, recent=True, amount=900)["fraud_flag"], "none"),
        ("inconsistent dates are a fraud review", labels_for(inconsistent=True)["fraud_flag"], "review"),
        ("ongoing leak needs emergency repair", labels_for(claim_type="home_escape_of_water", ongoing=True)["next_action"], "arrange_emergency_repair"),
        ("missing details request documents", labels_for(missing=True, amount=None)["next_action"], "request_documents"),
        ("doubt over cover goes to coverage review", labels_for(coverage_doubt=True)["next_action"], "refer_to_coverage_review"),
        ("amount of 5000 is high", labels_for(amount=5000)["severity"], "high"),
        ("minor injury lifts a low amount to medium", labels_for(injury="minor", amount=200)["severity"], "medium"),
    ]
    for name, got, want in rule_cases:
        record("rule: " + name, got == want, f"got {got}, want {want}")

    failed = [c for c in checks if not c["passed"]]
    print(json.dumps({"self_test": "passed" if not failed else "failed", "checks": checks}, indent=2, ensure_ascii=False))
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output folder. Default: ./.byow-work/dataset.")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="Seed for every split. Default: 20261023.")
    parser.add_argument("--train", type=int, default=DEFAULT_COUNTS["train"], help="Records in train.jsonl (at least 1). Default: 2000.")
    parser.add_argument("--eval", type=int, default=DEFAULT_COUNTS["eval"], help="Records in eval.jsonl (at least 1). Default: 200.")
    parser.add_argument("--heldout", type=int, default=DEFAULT_COUNTS["heldout"], help="Records in heldout.jsonl (at least 1). Default: 200.")
    parser.add_argument("--ood", type=int, default=DEFAULT_COUNTS["ood"], help="Records in ood.jsonl (at least 0). Default: 40.")
    parser.add_argument("--epochs", type=int, default=1, help="Epochs for the token estimate. Default: 1.")
    parser.add_argument("--self-test", action="store_true", help="Check determinism, vocabularies, label rules and split separation, then exit.")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    counts = {"train": args.train, "eval": args.eval, "heldout": args.heldout, "ood": args.ood}
    if min(args.train, args.eval, args.heldout) < 1 or args.ood < 0 or args.epochs < 1:
        print(json.dumps({"error": "train, eval and heldout must be at least 1, ood at least 0, epochs at least 1"}))
        return 2

    splits = build_splits(args.seed, counts)
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    manifest_splits: dict[str, dict] = {}
    for name, records in splits.items():
        data = serialise(records)
        path = out / f"{name}.jsonl"
        path.write_bytes(data)
        entry: dict = {
            "file": path.name,
            "records": len(records),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "labelled": bool(records) and is_labelled(records),
        }
        if entry["labelled"]:
            entry["label_distribution"] = label_distribution(records)
        manifest_splits[name] = entry

    characters = content_characters(splits["train"])
    tokens_estimate = characters // 4
    estimate = {
        "basis": "characters of message content in train.jsonl divided by four; an estimate, not a tokenizer count",
        "train_characters": characters,
        "train_tokens_estimate": tokens_estimate,
        "epochs": args.epochs,
        "train_tokens_times_epochs_estimate": tokens_estimate * args.epochs,
    }

    manifest = {
        "generator": "make_dataset.py",
        "generator_version": GENERATOR_VERSION,
        "seed": args.seed,
        "counts": counts,
        "organisation": ORGANISATION,
        "description": DESCRIPTION,
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "vocabularies": VOCABULARIES,
        "label_rules": LABEL_RULES,
        "splits": manifest_splits,
        "training_token_estimate": estimate,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

    print(json.dumps({
        "out": str(out.resolve()),
        "seed": args.seed,
        "files": {name: {"records": e["records"], "sha256": e["sha256"]} for name, e in manifest_splits.items()},
        "training_token_estimate": estimate,
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
