import 'package:flutter/material.dart';

/// Who runs NetPulse, as it should appear in the Privacy Policy and Terms. Put your own name or your
/// business's registered name here.
const legalOperator = 'NetPulse';

/// An email address for privacy and legal requests. Leave empty to say only that people can reach you through
/// the app's "Report an issue" feature (which always works); fill it in to show the address as well.
const legalContactEmail = '';

const legalLastUpdated = 'October 16, 2026';

class _Section {
  final String heading;
  final List<String> paragraphs; // plain paragraphs
  final List<String> bullets; // shown as a list after the paragraphs
  const _Section(this.heading, {this.paragraphs = const [], this.bullets = const []});
}

String get _contactLine => legalContactEmail.isEmpty
    ? 'Open the Account tab in the app and choose "Report an issue", and say that your message is about privacy or '
        'about these terms.'
    : 'Email $legalContactEmail, or open the Account tab in the app and choose "Report an issue".';

List<_Section> _privacySections() => [
      const _Section('About this policy', paragraphs: [
        'NetPulse is a mobile app for viewing your internet account, bills and payments, paying your bill, and '
            'managing your plan and add-ons. This policy explains what personal information the app and its server '
            'collect, why, who sees it, and the choices and rights you have. It follows the Philippines\' Data '
            'Privacy Act of 2012 (Republic Act No. 10173) and its implementing rules.',
        'The personal information controller is $legalOperator ("we", "us"). By creating an account and ticking '
            'the box at registration, you confirm you have read this policy.',
      ]),
      const _Section('What we collect', paragraphs: [
        'Information you give us:',
      ], bullets: [
        'Registration details: email address, password, first and last name, and mobile number.',
        'If you sign in with Google: your Google email address and Google\'s account identifier. We never see your Google password.',
        'Account links: the internet account numbers you ask to link to your login, and the status of those requests.',
        'Messages you send through "Report an issue", including the account and category you choose.',
        'Changes you make: a new email, mobile number, password, plan or add-on.',
        'Information about your internet account that already exists in our billing records and is shown to you once the account is linked: account number, account holder name, service address, registered mobile number, plan, bills, balance, due date and payment history.',
        'Payment details are entered on our payment provider\'s secure page, not in the app. We receive only the result and a reference (amount, status, date). We do not receive or store your card or e-wallet details.',
      ]),
      const _Section('Information the app creates or stores on your phone', bullets: [
        'A sign-in token. With "Remember me" ticked it is kept in your phone\'s secure storage so you stay signed in; with it unticked it is kept only in memory and is removed when the app closes. The tick-box setting itself is stored on the phone.',
        'Due-date reminders. If you allow notifications, reminders are scheduled on your phone from your bill details. The app does not send your notification choices to us.',
        'The app does not contain advertising or third-party analytics trackers.',
      ]),
      const _Section('Technical information', paragraphs: [
        'Our server records technical information needed to run and protect the service, such as request times, error messages and the number of recent attempts at sensitive actions (to block repeated guessing of passwords and codes).',
      ]),
      const _Section('Why we use it', bullets: [
        'To create and secure your login, and to confirm it is really you (for example, by emailing or texting a one-time code).',
        'To show your bills, balance and payments, and to process payments, plan changes and add-ons.',
        'To review and approve requests to link an internet account to your login, which we do by hand.',
        'To send you service and security messages: verification codes, and notices when your password, email, mobile number or account is changed or deleted.',
        'To answer issues you report and to improve the reliability of the service.',
        'To prevent fraud and misuse, and to meet legal obligations.',
      ]),
      const _Section('Who we share it with', paragraphs: [
        'We do not sell your personal information and we do not use it for advertising. We share the minimum needed with service providers who help us run NetPulse:',
      ], bullets: [
        'Email delivery (Gmail/Google): your email address and the content of the code or notice we send.',
        'SMS delivery (textbee): the mobile number and text of the code or notice we send.',
        'Payment processing (PayMongo): the amount, a reference for your payment and a description, so you can pay by card or e-wallet on their page.',
        'Google Sign-In: only if you choose to sign in with Google.',
        'Speed test (Cloudflare): if you run the speed test, test data is exchanged with Cloudflare\'s public speed-test servers. They see your IP address, like any website you visit; no account details are sent.',
        'Hosting and infrastructure providers that store our servers and database.',
        'Authorities, courts or other parties, only when the law requires it or to protect rights and safety.',
      ]),
      const _Section('Where it is stored', paragraphs: [
        'Your information is kept on servers operated by or for us. Some of our providers may process data outside the Philippines. We require them to protect it appropriately.',
      ]),
      const _Section('How we protect it', bullets: [
        'Passwords are never stored as plain text; they are salted and hashed.',
        'Sessions use signed tokens. Changing or resetting your password signs you out of every device.',
        'Changing your email, mobile number or password, switching plans, adding or removing add-ons, unlinking an account and deleting your login all ask for your password again. Email and mobile changes also need a one-time code, which expires after 3 minutes.',
        'Repeated attempts at sensitive actions are rate-limited.',
        'We transmit data over encrypted connections (HTTPS) in the live service.',
        'No system is perfectly secure. If a breach affects your personal information we will notify you and the National Privacy Commission as the law requires.',
      ]),
      const _Section('How long we keep it', bullets: [
        'Login details (email, password hash, name, mobile number, link requests and the links to your internet accounts) are kept while your login exists, and deleted when you delete your login in the app.',
        'Billing, payment and subscription records about your internet account belong to the service record, not to your login. They are kept as long as needed to provide the service and to meet accounting, tax and legal requirements, and are not removed when you delete your login.',
        'One-time codes are kept only in memory and expire after 3 minutes.',
        'Copies in backups may remain for a limited time after deletion before they are overwritten.',
      ]),
      const _Section('Your rights', paragraphs: [
        'Under the Data Privacy Act you have the right to:',
      ], bullets: [
        'be informed about how your data is processed (this policy);',
        'access your personal information;',
        'correct inaccurate information (you can change your email, mobile number and password in the Account tab);',
        'object to processing, and withdraw consent where processing is based on consent;',
        'ask for your data to be blocked, removed or destroyed (you can delete your login in the Account tab);',
        'data portability, where it applies;',
        'claim damages if you are harmed by inaccurate, incomplete, outdated, false or unlawfully obtained data; and',
        'complain to the National Privacy Commission (privacy.gov.ph).',
      ]),
      _Section('Children', paragraphs: [
        'NetPulse is meant for subscribers and household members who are at least 18 years old. We do not knowingly collect information from children. If you believe a child has registered, tell us and we will delete the login.',
      ]),
      const _Section('Changes to this policy', paragraphs: [
        'We may update this policy. When the changes are significant we will tell you in the app or by email. The date at the top shows the latest version.',
      ]),
      _Section('Contact us', paragraphs: [_contactLine]),
    ];

List<_Section> _termsSections() => [
      _Section('Agreement', paragraphs: [
        'These Terms & Conditions are an agreement between you and $legalOperator ("we", "us") about your use of the NetPulse app and service. By creating an account and ticking the box at registration, or by using the app, you accept them and our Privacy Policy. If you do not agree, do not use NetPulse.',
      ]),
      const _Section('What NetPulse does', paragraphs: [
        'NetPulse lets you sign in, link your internet account, see your plan, bills, balance and payment history, pay your bill, switch plans, add or remove add-ons, receive reminders and report issues. It is an account-management tool for your internet subscription. It is not itself the internet service.',
      ]),
      const _Section('Who can use it', bullets: [
        'You must be at least 18 and able to enter into a binding agreement.',
        'You may link only an internet account that you hold or are authorised to manage.',
        'The information you give us must be true, complete and kept up to date.',
      ]),
      const _Section('Your login and security', bullets: [
        'You are responsible for keeping your password, one-time codes and phone secure, and for what happens under your login.',
        'Do not share your password or codes with anyone. We will never ask you for them.',
        'Tell us right away if you think someone else has accessed your login. Changing your password signs out every device.',
        'Sensitive actions ask for your password again, and some need a one-time code. These checks exist to protect you; please do not try to get around them.',
        'If "Remember me" is ticked, anyone who can open your phone can open your account. Leave it unticked on shared devices.',
      ]),
      const _Section('Linking an account', paragraphs: [
        'Linking is not automatic. When you submit an account number we receive a request, check it against our records, and approve or decline it, which we aim to do within 24 hours. We may decline a request, or later remove a link, if we cannot confirm that you are entitled to see that account. You will be told by email.',
      ]),
      const _Section('Bills, payments and charges', bullets: [
        'Amounts, due dates and plans shown in the app come from our billing records. If something looks wrong, report it through "Report an issue" and we will review it.',
        'Payments are processed by a third-party provider (currently PayMongo) on its own secure page, under its own terms. We do not see or store your card or e-wallet details.',
        'A payment is counted when the provider confirms it. This can take a short time, and a payment that fails or is not confirmed does not reduce your balance. Keep your payment receipt or reference.',
        'You are responsible for the fees your payment method or e-wallet may charge.',
        'Not paying your bill on time can lead to the actions set out in your service agreement with us, such as reminders, suspension or disconnection. Using NetPulse does not change that agreement.',
      ]),
      const _Section('Plans and add-ons', bullets: [
        'You can switch plans in the app only when you have no amount due. The change takes effect straight away and your following bills reflect the new plan\'s monthly fee.',
        'An add-on you add is charged to your current bill straight away and stays until you remove it. Removing it takes its fee off your balance.',
        'Prices and availability can change. We will show the price before you confirm, and each change asks for your password.',
      ]),
      const _Section('What you must not do', bullets: [
        'Use NetPulse for anything unlawful, fraudulent or harmful.',
        'Try to see another person\'s account, or to guess passwords or codes.',
        'Interfere with, overload, probe or attack the app, the server or our providers.',
        'Copy, reverse-engineer or resell the app or its content, except where the law allows it.',
        'Send false, abusive or misleading reports.',
      ]),
      const _Section('Notifications and messages', paragraphs: [
        'We send you verification codes and security notices by email and SMS, and the app can show due-date reminders on your phone if you allow notifications. Security and verification messages are part of the service and cannot be switched off. Standard message charges from your mobile carrier may apply.',
      ]),
      const _Section('Ending your use', paragraphs: [
        'You can delete your login at any time in the Account tab; it asks for your password first. Deleting your login does not cancel your internet subscription or erase your billing history, which stay in our service records as explained in the Privacy Policy. We may suspend or close a login that breaks these terms, is used fraudulently, or puts the service or other users at risk.',
      ]),
      const _Section('Availability', paragraphs: [
        'We work to keep NetPulse available and accurate, but we do not promise that it will always be uninterrupted, error-free or free of delays. We may change, pause or stop features, for example for maintenance. Information shown in the app is for your convenience; for a dispute about a charge, our billing records, once reviewed, are what count.',
      ]),
      const _Section('Limits of our responsibility', paragraphs: [
        'To the fullest extent the law allows, NetPulse is provided "as is", and we are not liable for indirect or consequential loss, lost profits, or loss caused by things outside our reasonable control, such as network or power outages, your device, your mobile carrier or email provider, or the acts of third-party providers. Nothing in these terms limits any responsibility we cannot lawfully limit, including rights you have as a consumer under Philippine law.',
      ]),
      const _Section('Changes to these terms', paragraphs: [
        'We may update these terms from time to time. When a change is significant we will tell you in the app or by email. If you keep using NetPulse after a change takes effect, you accept the updated terms. If you do not agree, you can delete your login.',
      ]),
      const _Section('Governing law', paragraphs: [
        'These terms are governed by the laws of the Republic of the Philippines. Disputes will first be handled in good faith through our support channel; if they cannot be resolved there, the proper courts of the Philippines have jurisdiction.',
      ]),
      _Section('Contact us', paragraphs: [_contactLine]),
    ];

/// Shows the Privacy Policy or the Terms & Conditions as a scrolling page.
class LegalScreen extends StatelessWidget {
  final bool privacy; // true: Privacy Policy, false: Terms & Conditions
  const LegalScreen.privacy({super.key}) : privacy = true;
  const LegalScreen.terms({super.key}) : privacy = false;

  @override
  Widget build(BuildContext context) {
    final title = privacy ? 'Privacy Policy' : 'Terms & Conditions';
    final sections = privacy ? _privacySections() : _termsSections();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
          Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Last updated: $legalLastUpdated', style: TextStyle(color: theme.hintColor)),
          const SizedBox(height: 16),
          for (final s in sections) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(s.heading, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            for (final p in s.paragraphs)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p, style: const TextStyle(height: 1.4))),
            for (final b in s.bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('•  ', style: TextStyle(height: 1.4)),
                  Expanded(child: Text(b, style: const TextStyle(height: 1.4))),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
