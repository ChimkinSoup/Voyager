import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/google_auth_config.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  var _isSignUp = false;
  var _loading = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Puts the caret back after an attempt — the fields and buttons are
  /// disabled while it runs, which drops their focus — in the field most
  /// likely to need fixing: Email if it's empty or [email] says the attempt
  /// was about it, else Password. After the frame, once the fields are
  /// enabled again.
  void _refocusField({bool email = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (email || _emailController.text.trim().isEmpty
              ? _emailFocus
              : _passwordFocus)
          .requestFocus();
    });
  }

  Future<void> _runAuth(
    Future<void> Function() action, {
    bool aboutEmail = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => _error = _formatAuthError(e));
      _refocusField(email: aboutEmail);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Email and password are required.';
        _success = null;
      });
      _refocusField();
      return;
    }
    await _runAuth(() async {
      final auth = ref.read(authRepositoryProvider);
      if (_isSignUp) {
        await auth.signUpWithEmail(email, password);
      } else {
        await auth.signInWithEmail(email, password);
      }
    });
  }

  Future<void> _googleSignIn() async {
    await _runAuth(() => ref.read(authRepositoryProvider).signInWithGoogle());
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _error = 'Enter your email to reset your password.';
        _success = null;
      });
      _refocusField();
      return;
    }
    // Failed or sent, the page stays: focus goes back to Email either way.
    await _runAuth(() async {
      await ref.read(authRepositoryProvider).sendPasswordResetEmail(email);
      setState(() {
        _success =
            'If an account exists for this email, a password reset link has been sent.';
      });
      _refocusField(email: true);
    }, aboutEmail: true);
  }

  String _formatAuthError(Object error) {
    final text = error.toString();
    const prefix = 'Exception: ';
    if (text.startsWith(prefix)) {
      return text.substring(prefix.length);
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    // A signed-in account is checked against this device's local data before
    // it is let in, which can take a while (a wipe, a drain to finish) — and
    // must not be started over by a second sign-in meanwhile.
    return ValueListenableBuilder<bool>(
      valueListenable: ref.watch(authNotifierProvider).settlingListenable,
      builder: (context, settling, _) =>
          _buildForm(context, busy: _loading || settling),
    );
  }

  Widget _buildForm(BuildContext context, {required bool busy}) {
    final showGoogleSignIn = !isWindows || isGoogleOAuthReadyForDesktop;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Voyager',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  LabeledTextField(
                    label: 'Email',
                    controller: _emailController,
                    focusNode: _emailFocus,
                    // Not on Android, where focus raises the soft keyboard
                    // over the buttons before the user has chosen a field.
                    autofocus: !isAndroid,
                    enabled: !busy,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 12),
                  LabeledTextField(
                    label: 'Password',
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: true,
                    enabled: !busy,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (!_isSignUp) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GlassButton(
                        canRequestFocus: true,
                        onPressed: busy ? null : _resetPassword,
                        label: 'Forgot password?',
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: AppFonts.style(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_success != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _success!,
                      style: AppFonts.style(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  GlassButton(
                    canRequestFocus: true,
                    onPressed: busy ? null : _submit,
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isSignUp ? 'Sign up' : 'Sign in'),
                  ),
                  const SizedBox(height: 8),
                  if (showGoogleSignIn) ...[
                    GlassButton(
                      canRequestFocus: true,
                      onPressed: busy ? null : _googleSignIn,
                      label: 'Continue with Google',
                    ),
                    const SizedBox(height: 8),
                  ],
                  GlassButton(
                    canRequestFocus: true,
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            _isSignUp = !_isSignUp;
                            _error = null;
                            _success = null;
                          }),
                    label: _isSignUp
                        ? 'Have an account? Sign in'
                        : 'Create account',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
