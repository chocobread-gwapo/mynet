String peso(int centavos) {
  final whole = (centavos.abs() ~/ 100)
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${centavos < 0 ? '-' : ''}₱$whole.${(centavos.abs() % 100).toString().padLeft(2, '0')}';
}

String fmtDate(String iso) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.parse(iso);
  return '${m[d.month - 1]} ${d.day}, ${d.year}';
}
