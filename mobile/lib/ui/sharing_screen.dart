import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/money.dart';
import '../core/sync.dart';
import 'home.dart';
import 'widgets.dart';

/// Share the House space with your partner: sign in, then start a household or join one with
/// the partner's invite code. Same free Supabase project and accounts as the web app.
class SharingScreen extends StatefulWidget {
  const SharingScreen({super.key});
  @override
  State<SharingScreen> createState() => _SharingScreenState();
}

class _SharingScreenState extends State<SharingScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  final code = TextEditingController();
  bool busy = false;
  bool needsHousehold = false;
  String? problem;
  String? info;

  @override
  void initState() {
    super.initState();
    name.text = ModelScope.read(context).store.currentUser.name;
  }

  @override
  void dispose() {
    for (final c in [email, password, name, code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      problem = null;
      info = null;
    });
    try {
      await work();
    } catch (e) {
      problem = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final sync = model.sync;
    final pal = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Share with partner')),
      body: AbsorbPointer(
        absorbing: busy,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (busy) const LinearProgressIndicator(),
            if (sync == null)
              const SectionCard(
                children: [
                  Text('Sharing is not switched on in this version of the app.'),
                  Muted('Everything still works on this phone. Use Settings > Backup to move data between phones meanwhile.'),
                ],
              )
            else if (sync.isConnected)
              ..._connected(context, sync)
            else if (needsHousehold || sync.client.session != null)
              ..._household(context, sync)
            else
              ..._signIn(context, sync),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  problem!,
                  key: const Key('sharingProblem'),
                  style: TextStyle(color: pal.over),
                ),
              ),
            if (info != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(info!, key: const Key('sharingInfo')),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _signIn(BuildContext context, SyncEngine sync) => [
    SectionCard(
      title: 'Sign in',
      children: [
        const Muted('Use the same account as in the web app. Your Personal space stays private; only the House space is shared.'),
        TextField(
          key: const Key('email'),
          controller: email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        TextField(
          key: const Key('password'),
          controller: password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password (at least 6 characters)'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('signIn'),
          onPressed: () => run(() async {
            final r = await sync.signIn(email.text.trim(), password.text);
            if (r == ResumeResult.needsHousehold) needsHousehold = true;
          }),
          child: const Text('Sign in'),
        ),
        const SizedBox(height: 6),
        OutlinedButton(
          key: const Key('signUp'),
          onPressed: () {
            if (email.text.trim().isEmpty || password.text.length < 6) {
              setState(() => problem = 'Enter your email and a password of at least 6 characters.');
              return;
            }
            run(() async {
              final signedIn = await sync.signUp(email.text.trim(), password.text);
              if (signedIn) {
                needsHousehold = true;
              } else {
                info = 'Account created. Open the confirmation email, then come back and sign in.';
              }
            });
          },
          child: const Text('Create an account'),
        ),
      ],
    ),
  ];

  List<Widget> _household(BuildContext context, SyncEngine sync) => [
    SectionCard(
      children: [
        const Muted("Signed in. Now start a household, or join your partner's with their code."),
        TextField(
          key: const Key('displayName'),
          controller: name,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Your name'),
        ),
        FilledButton(
          key: const Key('createHousehold'),
          onPressed: () => run(() async {
            await sync.createHousehold(name.text);
            if (mounted) toast(this.context, 'Household created');
          }),
          child: const Text("Start sharing (I'm the first one)"),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Muted('or', align: TextAlign.center),
        ),
        TextField(
          key: const Key('inviteCode'),
          controller: code,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          decoration: const InputDecoration(labelText: "Partner's invite code", hintText: 'e.g. 4F7A21C9'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('joinHousehold'),
          onPressed: () {
            if (code.text.trim().isEmpty) {
              setState(() => problem = 'Enter the invite code.');
              return;
            }
            run(() async {
              await sync.joinHousehold(code.text, name.text);
              if (mounted) toast(this.context, 'Joined the household');
            });
          },
          child: const Text('Join with a code'),
        ),
        const SizedBox(height: 6),
        const Muted('Entries already on this phone are moved into your account.'),
        TextButton(
          onPressed: () => run(() async {
            await sync.signOut();
            needsHousehold = false;
          }),
          child: const Text('Sign out'),
        ),
      ],
    ),
  ];

  List<Widget> _connected(BuildContext context, SyncEngine sync) {
    final model = ModelScope.of(context);
    final store = model.store;
    final invite = store.data.settings.inviteCode;
    final last = sync.meta.lastSyncAt;
    final status = switch (sync.state) {
      SyncState.syncing => 'Syncing…',
      SyncState.error => 'Not synced: ${sync.errorText ?? ''}',
      _ => sync.pendingCount > 0 ? '${sync.pendingCount} change(s) waiting' : 'Up to date',
    };
    return [
      SectionCard(
        title: 'Signed in as ${store.currentUser.name}',
        children: [
          Text(status, key: const Key('syncStatus')),
          if (last != null) Muted('Last synced ${timeAgo(last)}'),
          const SizedBox(height: 8),
          OutlinedButton(key: const Key('syncNow'), onPressed: () => run(sync.syncNow), child: const Text('Sync now')),
        ],
      ),
      if (invite != null && store.data.users.length < 2)
        SectionCard(
          title: 'Invite code for your partner',
          children: [
            SelectableText(
              invite,
              key: const Key('inviteCodeShown'),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontFamily: 'monospace', letterSpacing: 2),
            ),
            const Muted('Your partner opens the app, signs in, taps "Join with a code" and enters this code.'),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: invite));
                    toast(context, 'Code copied');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(text: 'Join my budget: open Settings > Share with partner and enter the code $invite'),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
        )
      else
        SectionCard(
          children: [
            Muted(
              '${store.data.users.where((u) => u.id != store.currentUser.id).map((u) => u.name).join(', ')} sees the House space. Your Personal space is only on your phone and your account.',
            ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: OutlinedButton(
          key: const Key('signOut'),
          onPressed: () async {
            if (await confirm(
              context,
              'Sign out?',
              'Your entries stay on this phone, but stop syncing until you sign in again.',
              'Sign out',
            )) {
              await run(sync.signOut);
            }
          },
          child: const Text('Sign out'),
        ),
      ),
    ];
  }
}

String timeAgo(String iso) {
  final t = DateTime.fromMillisecondsSinceEpoch(Timestamps.millis(iso));
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${(s / 60).round()} min ago';
  return '${shortDay(DateKey.day(t))} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
