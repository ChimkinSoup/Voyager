import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/study_models.dart';

/// Pre-defined seed cards containing varied content styles:
/// - Simple LaTeX
/// - Complex LaTeX (matrices, differential equations, summations)
/// - Very long text (multi-paragraph prose)
/// - Short text (single words / acronyms)
/// - Mixed prose + math formatting
const _cardPool = <({String front, String back})>[
  // Simple LaTeX
  (
    front: r'Mass-energy equivalence equation',
    back: r'$E = mc^2$, where $E$ is energy, $m$ is mass, and $c = 3 \times 10^8 \text{ m/s}$.',
  ),
  (
    front: r'Power Rule for derivatives',
    back: r'$\frac{d}{dx}\left(x^n\right) = n x^{n-1}$',
  ),
  (
    front: r'Fundamental limit of calculus',
    back: r'$\lim_{x \to 0} \frac{\sin x}{x} = 1$',
  ),
  (
    front: r'Pythagorean Theorem',
    back: r'$a^2 + b^2 = c^2$',
  ),
  (
    front: r'Quadratic Formula',
    back: r'$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$',
  ),
  (
    front: r'Integration of $e^{ax}$',
    back: r'$\int e^{ax} \, dx = \frac{1}{a} e^{ax} + C$',
  ),

  // Complex LaTeX
  (
    front: r'Schrödinger Time-Dependent Equation',
    back: r'$i\hbar \frac{\partial}{\partial t}\Psi(\mathbf{r},t) = \left[ -\frac{\hbar^2}{2m}\nabla^2 + V(\mathbf{r},t) \right]\Psi(\mathbf{r},t)$',
  ),
  (
    front: r'2x2 Matrix Inverse Formula',
    back: r'If $A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}$, then $A^{-1} = \frac{1}{ad-bc} \begin{pmatrix} d & -b \\ -c & a \end{pmatrix}$ provided $ad-bc \neq 0$.',
  ),
  (
    front: r"Maxwell's Faraday Law of Induction",
    back: r'$\oint_C \mathbf{E} \cdot d\mathbf{l} = -\frac{d}{dt} \iint_S \mathbf{B} \cdot d\mathbf{A}$',
  ),
  (
    front: r'Euler-Lagrange Equation',
    back: r'$\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}_i} \right) - \frac{\partial L}{\partial q_i} = 0$',
  ),
  (
    front: r'Riemann Zeta Function definition',
    back: r'$\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s} = \frac{1}{1^s} + \frac{1}{2^s} + \frac{1}{3^s} + \dots$',
  ),
  (
    front: r'Fourier Transform integral',
    back: r'$\hat{f}(\xi) = \int_{-\infty}^{\infty} f(x) e^{-2\pi i x \xi} \, dx$',
  ),

  // Very Long Text
  (
    front: r'Explain the difference between Synchronous and Asynchronous execution in single-threaded environments.',
    back: r'In a single-threaded runtime (such as JavaScript or Dart isolates), synchronous operations execute sequentially and block the execution thread until completion. No other tasks or rendering routines can process while a synchronous block runs.' '\n\n' r'In contrast, asynchronous operations delegate long-running tasks (like I/O, file reading, or network requests) to background subsystems. Upon completion, callback events or futures are queued, allowing the single thread to maintain responsive UI frames without blocking.',
  ),
  (
    front: r'Describe the architectural principles of Content Delivery Networks (CDNs) and Anycast DNS routing.',
    back: r'A Content Delivery Network (CDN) is a globally distributed network of proxy servers designed to serve static assets with high availability and spatial proximity.' '\n\n' r'CDNs heavily leverage Anycast DNS routing: multiple edge servers in different locations share the exact same IP address. BGP routes client packets along the shortest network hop to the nearest PoP, minimizing latency and buffering DDoS traffic at edge nodes.',
  ),
  (
    front: r'Detailed summary of the TCP 3-Way Handshake protocol',
    back: r'The Transmission Control Protocol establishes a reliable connection via a 3-Way Handshake:' '\n' r'1. SYN: Client sends Initial Sequence Number ($ISN_c$).' '\n' r'2. SYN-ACK: Server acknowledges with $ACK = ISN_c + 1$ and sends $ISN_s$.' '\n' r'3. ACK: Client responds with $ACK = ISN_s + 1$.' '\n\n' r'Once completed, the connection transitions to ESTABLISHED for full-duplex transmission.',
  ),

  // Short Text
  (
    front: r'DNS',
    back: r'Domain Name System',
  ),
  (
    front: r'HTTP 404',
    back: r'Not Found',
  ),
  (
    front: r'RAM',
    back: r'Random Access Memory',
  ),
  (
    front: r'Speed of Light ($c$)',
    back: r'$3 \times 10^8 \text{ m/s}$',
  ),
  (
    front: r'H2O',
    back: r'Water',
  ),
  (
    front: r'ACID Principles',
    back: r'Atomicity, Consistency, Isolation, Durability',
  ),

  // Mixed Text + Math
  (
    front: r'Evaluate: $\int_0^{\pi} \sin(x) \, dx$',
    back: r'To evaluate $\int_0^{\pi} \sin(x) \, dx$:' '\n' r'1. Antiderivative: $-\cos(x)$' '\n' r'2. Evaluate bounds: $[-\cos(\pi)] - [-\cos(0)] = -(-1) - (-1) = 2$' '\n\n' r'Result: $2$',
  ),
  (
    front: r'Derivative of $f(x) = \ln(x^2 + 1)$',
    back: r'Using the Chain Rule:' '\n' r'$f^\prime(x) = \frac{1}{x^2 + 1} \cdot \frac{d}{dx}(x^2 + 1) = \frac{2x}{x^2 + 1}$',
  ),
  (
    front: r'Taylor Series expansion of $e^x$',
    back: r'$e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \dots$',
  ),
];

const _deckTopics = [
  'Math & Physics Master',
  'Advanced Calculus & Limits',
  'Computer Science Core',
  'Quantum Mechanics & Optics',
  'Randomized Test Deck',
];

/// Populates the Study Page with a newly generated deck of randomized size
/// (25 to 45 cards) containing simple & complex LaTeX, long prose, short QA,
/// and varied SRS mastery states.
Future<void> populateDebugStudyDeck(
  BuildContext context,
  WidgetRef ref, {
  String? parentFolderId,
  int targetCardCount = 30,
}) async {
  final rng = Random();
  final now = utcNow();
  final repo = ref.read(studyRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);

  final topic = _deckTopics[rng.nextInt(_deckTopics.length)];
  final deckName = 'Debug: $topic (${rng.nextInt(900) + 100})';
  final deckId = newId();

  final colors = [
    0xFF5C8BE0, // Blue
    0xFF4CAF7D, // Green
    0xFFE0A63A, // Amber
    0xFF9C27B0, // Purple
    0xFFE91E63, // Pink
  ];

  final deck = StudyDeck(
    id: deckId,
    createdAt: now,
    updatedAt: now,
    name: deckName,
    parentFolderId: parentFolderId,
    colorValue: colors[rng.nextInt(colors.length)],
  );

  await repo.upsertDeck(deck);
  remoteSync.pushStudyDeck(deck);

  final cards = <StudyCard>[];

  for (var i = 0; i < targetCardCount; i++) {
    final template = _cardPool[rng.nextInt(_cardPool.length)];

    // Vary SRS mastery profiles:
    // 0: New (unreviewed)
    // 1: Learning (sub-day interval)
    // 2: Due / Reviewing (multi-day interval, due today or past)
    // 3: Mastered (long interval, due in future)
    final profileIndex = rng.nextInt(4);
    double interval;
    double ease;
    DateTime dueAt;
    int reviewCount;

    switch (profileIndex) {
      case 0:
        interval = 0;
        ease = 2.5;
        reviewCount = 0;
        dueAt = now;
        break;
      case 1:
        interval = 0.5;
        ease = 2.3;
        reviewCount = 1 + rng.nextInt(2);
        dueAt = now;
        break;
      case 2:
        interval = 2.0 + rng.nextDouble() * 5.0;
        ease = 2.4;
        reviewCount = 3 + rng.nextInt(4);
        dueAt = now.subtract(Duration(hours: rng.nextInt(48)));
        break;
      case 3:
      default:
        interval = 21.0 + rng.nextDouble() * 30.0;
        ease = 2.6;
        reviewCount = 7 + rng.nextInt(10);
        dueAt = now.add(Duration(days: 3 + rng.nextInt(14)));
        break;
    }

    final card = StudyCard(
      id: newId(),
      createdAt: now.subtract(Duration(days: 10)),
      updatedAt: now,
      deckId: deckId,
      frontText: '${template.front}${targetCardCount > 25 ? " [#${i + 1}]" : ""}',
      backText: template.back,
      interval: interval,
      ease: ease,
      dueAt: dueAt,
      reviewCount: reviewCount,
    );

    cards.add(card);
    await repo.upsertCard(card);
    remoteSync.pushStudyCard(card);
  }

  ref.invalidate(studyDecksProvider);
  ref.invalidate(studyCardsProvider);
  ref.invalidate(studyDeckStatsProvider);
  ref.invalidate(studyStatsProvider);
  ref.invalidate(studyFoldersProvider);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Generated debug deck "$deckName" with ${cards.length} randomized cards.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
