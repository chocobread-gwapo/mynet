import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/core/validators.dart';
import 'package:mynet/legal.dart';
import 'package:mynet/screens/change_contact_screen.dart';
import 'package:mynet/screens/change_password_screen.dart';
import 'package:mynet/screens/report_issue_screen.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/password_confirm.dart';

class AccountPage extends StatefulWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const AccountPage(this.acct, this.onChanged, {super.key});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  Map<String, dynamic> get acct => widget.acct;
  Future<void> Function() get onChanged => widget.onChanged;
  int _meVersion = 0; // bumped to re-fetch the email / password status after a change

  /// Changing the email or mobile number, and deleting the account, all ask for the current password, and
  /// a login made only through Google has none yet. Offers to set one (through the same emailed-code flow as
  /// "Forgot password") and returns whether the caller can go ahead.
  Future<bool> _hasPasswordOrOffer(Map<String, dynamic> me) => ensurePassword(context, me);

  void _openSetPassword(Map<String, dynamic> me) => openSetPasswordScreen(context, me);

  Future<void> _changeEmail(Map<String, dynamic> me) async {
    if (!await _hasPasswordOrOffer(me) || !mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangeContactScreen(
        title: 'Change email address',
        intro: "Enter your new email address and your current password. We'll send a code to the new "
            "address to confirm it's yours.",
        fieldLabel: 'New email address',
        keyboard: TextInputType.emailAddress,
        validator: emailValidator,
        codeDescription: (value) => 'We sent a code to $value.',
        start: (value, password) => api.startEmailChange(value, password),
        confirm: (code) => api.confirmEmailChange(code),
        successMessage: 'Email address updated.',
      ),
    ));
    if (done == true && mounted) setState(() => _meVersion++);
  }

  Future<void> _changePassword(Map<String, dynamic> me) async {
    if (me['has_password'] != true) return _openSetPassword(me); // a Google-only login: nothing to "change" yet
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ChangePasswordScreen()));
  }

  Future<void> _changeMobile(Map<String, dynamic> me) async {
    if (!await _hasPasswordOrOffer(me) || !mounted) return;
    final accountId = acct['id'] as int;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangeContactScreen(
        title: 'Change mobile number',
        intro: "Enter the new mobile number for account ${acct['account_no']} and your current password. "
            "We'll text a code to the new number to confirm it's yours.",
        fieldLabel: 'New mobile number',
        keyboard: TextInputType.phone,
        validator: mobileValidator,
        codeDescription: (value) => 'We sent a code by SMS to $value.',
        start: (value, password) => api.startMobileChange(accountId, value, password),
        confirm: (code) => api.confirmMobileChange(accountId, code),
        successMessage: 'Mobile number updated.',
      ),
    ));
    if (done == true) await onChanged(); // reloads the account, which rebuilds this page with the new number
  }

  Future<void> _deleteAccount() async {
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> me;
    try {
      me = await api.me();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted || !await _hasPasswordOrOffer(me) || !mounted) return;
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => PasswordConfirmDialog(
        title: 'Delete your account?',
        message: "This permanently deletes your NetPulse login. Your internet subscription and billing "
            "records aren't affected, and you can sign up again and link your account later.",
        confirmLabel: 'Delete account',
        busyLabel: 'Deleting...',
        destructive: true,
        action: api.deleteAccount,
      ),
    );
    if (deleted == true) accountDeleted();
  }

  Future<void> _unlink() async {
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> me;
    try {
      me = await api.me();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted || !await _hasPasswordOrOffer(me) || !mounted) return;
    final id = acct['id'] as int;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => PasswordConfirmDialog(
        title: 'Unlink this account?',
        message: 'You can link it again later with the account number and registered mobile number.',
        confirmLabel: 'Unlink',
        busyLabel: 'Unlinking...',
        action: (pw) => api.unlink(id, pw),
      ),
    );
    if (done == true) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final plan = acct['plan'] as Map;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Panel(
        child: Column(children: [
          kv('Name', '${acct['holder_name']}'),
          kv('Account number', '${acct['account_no']}'),
          kv('Service address', '${acct['service_address']}'),
          kv('Plan', '${plan['name']}, ${plan['speed_mbps']} Mbps'),
          kv('Status', acct['status'] == 'ACTIVE' ? 'Active' : 'Suspended'),
        ]),
      ),
      // Sign-in details load separately: the email and whether there's a password belong to the login, not
      // to this internet account, so they come from their own request.
      Loader<Map<String, dynamic>>(
        key: ValueKey(_meVersion),
        load: api.me,
        builder: (c, me) {
          final hasPassword = me['has_password'] == true;
          return Panel(
            child: Column(children: [
              _editableRow(c, 'Email Address', '${me['email']}', 'Change email address', () => _changeEmail(me)),
              const Divider(height: 1),
              _editableRow(c, 'Password', hasPassword ? '••••••••••' : 'Not set',
                  hasPassword ? 'Change password' : 'Set password', () => _changePassword(me)),
              const Divider(height: 1),
              _editableRow(c, 'Mobile Number', '${acct['mobile']}', 'Change mobile number', () => _changeMobile(me)),
            ]),
          );
        },
      ),
      OutlinedButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ReportIssueScreen(accountId: acct['id'] as int))),
        child: const Text('Report an issue'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _unlink, child: const Text('Unlink this account')),
      const SizedBox(height: 8),
      FilledButton(
        style: bigButton.merge(
            FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318), foregroundColor: Colors.white)),
        onPressed: _deleteAccount,
        child: const Text('Delete Account'),
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegalScreen.privacy())),
          child: const Text('Privacy Policy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegalScreen.terms())),
          child: const Text('Terms & Conditions'),
        ),
      ]),
    ]);
  }
}

/// One line of the sign-in details panel: label on the left, the current value on the right with a small
/// "Change ..." link under it.
Widget _editableRow(BuildContext context, String label, String value, String linkText, VoidCallback onTap) {
  final primary = Theme.of(context).colorScheme.primary;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 108, child: Text(label)),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(linkText, style: TextStyle(fontSize: 12, color: primary)),
            ),
          ),
        ]),
      ),
    ]),
  );
}
