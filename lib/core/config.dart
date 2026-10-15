const appName = 'NetPulse';

const devSimulatePayments = true; // set to false once a real payment gateway is connected

/// How long the app can sit in the background before a login made WITHOUT "Remember me" is ended.
/// Change the number to taste; it has no effect on logins that did tick "Remember me".
const backgroundLogoutAfter = Duration(minutes: 5);

/// The Web OAuth client ID from Google Cloud Console (APIs & Services > Credentials) — the same value
/// GOOGLE_CLIENT_ID is set to on the server (they must match: the server checks the token was issued
/// for this exact client). Leave the placeholder in and the Google button shows a clear error when
/// tapped instead of breaking anything else in the app.
const googleServerClientId = '525298506900-qppp3bqo9i0f94jqol667fo3v4qf6c7l.apps.googleusercontent.com';
