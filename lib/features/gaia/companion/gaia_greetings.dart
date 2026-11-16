import 'dart:math';

/// Which bag a new-chat greeting is drawn from (GAIA_GREETINGS_HLD.md §4).
enum GaiaGreetingKind { general, named, morning, afternoon, evening, lateNight }

/// One line a new chat can open on.
class GaiaGreeting {
  const GaiaGreeting(this.kind, this.text);

  final GaiaGreetingKind kind;

  /// May contain `{name}`.
  final String text;

  bool get named => text.contains('{name}');

  String filled(String name) => text.replaceAll('{name}', name);
}

/// The pool (§6).
const kGaiaGreetings = <GaiaGreeting>[
  GaiaGreeting(GaiaGreetingKind.general, 'What can I help with?'),
  GaiaGreeting(GaiaGreetingKind.general, 'What are we working on?'),
  GaiaGreeting(GaiaGreetingKind.general, "What's on your mind?"),
  GaiaGreeting(GaiaGreetingKind.general, 'Ready when you are.'),
  GaiaGreeting(GaiaGreetingKind.general, 'Where should we start?'),
  GaiaGreeting(GaiaGreetingKind.general, "What's next?"),
  GaiaGreeting(GaiaGreetingKind.general, "Let's make something."),
  GaiaGreeting(GaiaGreetingKind.general, 'Ask me anything.'),
  GaiaGreeting(GaiaGreetingKind.general, 'What are we building today?'),
  GaiaGreeting(GaiaGreetingKind.general, "Got a question? I've got time."),
  GaiaGreeting(GaiaGreetingKind.general, 'Point me at a problem.'),
  GaiaGreeting(GaiaGreetingKind.general, 'What needs doing?'),
  GaiaGreeting(GaiaGreetingKind.general, 'Fresh page. What goes on it?'),
  GaiaGreeting(GaiaGreetingKind.general, "Let's figure it out together."),
  GaiaGreeting(GaiaGreetingKind.general, "What's the plan?"),
  GaiaGreeting(GaiaGreetingKind.general, "I'm all ears."),
  GaiaGreeting(GaiaGreetingKind.general, 'Throw me something tricky.'),
  GaiaGreeting(GaiaGreetingKind.general, 'What can I take off your plate?'),
  GaiaGreeting(GaiaGreetingKind.general, "Start anywhere. I'll keep up."),
  GaiaGreeting(GaiaGreetingKind.general, 'What are you curious about?'),
  GaiaGreeting(GaiaGreetingKind.general, "One thing at a time. What's first?"),
  GaiaGreeting(GaiaGreetingKind.general, 'Say the word.'),
  GaiaGreeting(GaiaGreetingKind.general, "Let's get into it."),
  GaiaGreeting(GaiaGreetingKind.general, "What's bugging you?"),
  GaiaGreeting(GaiaGreetingKind.general, 'Big idea or small fix?'),
  GaiaGreeting(GaiaGreetingKind.general, "Tell me what you're after."),
  GaiaGreeting(GaiaGreetingKind.general, 'Something to untangle?'),
  GaiaGreeting(GaiaGreetingKind.general, "Let's think this through."),
  GaiaGreeting(GaiaGreetingKind.named, "Hi, {name}. What's up?"),
  GaiaGreeting(GaiaGreetingKind.named, 'What are we working on, {name}?'),
  GaiaGreeting(GaiaGreetingKind.named, 'Good to see you, {name}.'),
  GaiaGreeting(GaiaGreetingKind.named, 'Welcome back, {name}.'),
  GaiaGreeting(GaiaGreetingKind.named, 'Ready when you are, {name}.'),
  GaiaGreeting(GaiaGreetingKind.named, "What's on your mind, {name}?"),
  GaiaGreeting(GaiaGreetingKind.named, 'Where to, {name}?'),
  GaiaGreeting(GaiaGreetingKind.named, "Hey {name}, what's next?"),
  GaiaGreeting(GaiaGreetingKind.named, 'At your service, {name}.'),
  GaiaGreeting(GaiaGreetingKind.named, "Let's get to it, {name}."),
  GaiaGreeting(GaiaGreetingKind.named, '{name}, what can I help with?'),
  GaiaGreeting(GaiaGreetingKind.named, 'Missed me, {name}?'),
  GaiaGreeting(GaiaGreetingKind.named, 'Your move, {name}.'),
  GaiaGreeting(GaiaGreetingKind.named, "What's the plan, {name}?"),
  GaiaGreeting(GaiaGreetingKind.morning, "Good morning. What's first?"),
  GaiaGreeting(GaiaGreetingKind.morning, 'Morning. Where do we start?'),
  GaiaGreeting(GaiaGreetingKind.morning, "Early start? Let's go."),
  GaiaGreeting(GaiaGreetingKind.morning, 'Morning, {name}. Coffee first?'),
  GaiaGreeting(GaiaGreetingKind.morning, 'Good morning, {name}.'),
  GaiaGreeting(GaiaGreetingKind.morning, 'Rise and shine, {name}.'),
  GaiaGreeting(GaiaGreetingKind.afternoon, "Good afternoon. What's next?"),
  GaiaGreeting(GaiaGreetingKind.afternoon, "Afternoon. What's on the list?"),
  GaiaGreeting(
    GaiaGreetingKind.afternoon,
    "Halfway through the day. What's up?",
  ),
  GaiaGreeting(
    GaiaGreetingKind.afternoon,
    "Afternoon, {name}. How's it going?",
  ),
  GaiaGreeting(GaiaGreetingKind.afternoon, 'Good afternoon, {name}.'),
  GaiaGreeting(GaiaGreetingKind.afternoon, 'Back at it, {name}?'),
  GaiaGreeting(GaiaGreetingKind.evening, "Good evening. What's left to do?"),
  GaiaGreeting(GaiaGreetingKind.evening, 'Evening. Anything to wrap up?'),
  GaiaGreeting(GaiaGreetingKind.evening, 'One more thing before tonight?'),
  GaiaGreeting(GaiaGreetingKind.evening, 'Evening, {name}. Winding down?'),
  GaiaGreeting(GaiaGreetingKind.evening, 'Good evening, {name}.'),
  GaiaGreeting(GaiaGreetingKind.evening, 'Long day, {name}?'),
  GaiaGreeting(GaiaGreetingKind.lateNight, "Up late? Let's make it count."),
  GaiaGreeting(GaiaGreetingKind.lateNight, 'Burning the midnight oil?'),
  GaiaGreeting(GaiaGreetingKind.lateNight, "Late one tonight. What's up?"),
  GaiaGreeting(GaiaGreetingKind.lateNight, "Still up, {name}? I'm here."),
  GaiaGreeting(GaiaGreetingKind.lateNight, 'Night owl mode, {name}?'),
  GaiaGreeting(GaiaGreetingKind.lateNight, "Can't sleep, {name}?"),
];

/// The time window [hour] (local, 0–23) falls in.
GaiaGreetingKind gaiaGreetingWindow(int hour) => switch (hour) {
  >= 5 && < 12 => GaiaGreetingKind.morning,
  >= 12 && < 17 => GaiaGreetingKind.afternoon,
  >= 17 && < 22 => GaiaGreetingKind.evening,
  _ => GaiaGreetingKind.lateNight,
};

/// A shuffle bag per kind, picked by weight (§4.2). For this run only.
class GaiaGreetings {
  GaiaGreetings({Random? random, DateTime Function()? now})
    : _random = random ?? Random(),
      _now = now ?? DateTime.now;

  final Random _random;
  final DateTime Function() _now;
  final _bags = <GaiaGreetingKind, List<GaiaGreeting>>{};

  /// Each bag's last line, kept out of the start of its next shuffle.
  final _last = <GaiaGreetingKind, GaiaGreeting>{};

  /// How many draws after a refill the last line is kept out of.
  static const _gap = 3;

  /// The next line: the current window 15%, the name bag 30% while
  /// [hasName], general the rest.
  GaiaGreeting draw({required bool hasName}) {
    final roll = _random.nextDouble();
    final kind = roll < 0.15
        ? gaiaGreetingWindow(_now().hour)
        : hasName && roll < 0.45
        ? GaiaGreetingKind.named
        : GaiaGreetingKind.general;
    bool showable(GaiaGreeting greeting) => hasName || !greeting.named;
    final bag = _bags[kind] ??= [];
    var at = bag.indexWhere(showable);
    if (at < 0) {
      bag
        ..clear()
        ..addAll(kGaiaGreetings.where((greeting) => greeting.kind == kind))
        ..shuffle(_random);
      _keepBack(bag, _last[kind], showable);
      at = bag.indexWhere(showable);
    }
    return _last[kind] = bag.removeAt(at);
  }

  /// Moves [last] past the first [_gap] lines of [bag] that can be shown,
  /// or as far back as a short bag allows, by a swap with a later one.
  void _keepBack(
    List<GaiaGreeting> bag,
    GaiaGreeting? last,
    bool Function(GaiaGreeting) showable,
  ) {
    if (last == null) return;
    final slots = [
      for (final (i, greeting) in bag.indexed)
        if (showable(greeting)) i,
    ];
    final keep = min(_gap, slots.length - 1);
    final at = slots.indexOf(bag.indexOf(last));
    if (at < 0 || at >= keep) return;
    final to = slots[keep + _random.nextInt(slots.length - keep)];
    bag[slots[at]] = bag[to];
    bag[to] = last;
  }
}
