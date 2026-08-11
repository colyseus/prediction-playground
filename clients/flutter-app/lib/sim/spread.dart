import 'random.dart';

const int pellets = 6;
const double spreadRad = 0.38;

/// The shotgun fan — SAME derivation on both sides, nothing random on the
/// wire: the seed is (input seq, synced per-room salt), so client and server
/// roll identical pellets for the same shot. The FPS demo's weapon-spread
/// pattern, minimized.
///
/// Writes into [out] when it can hold [pellets] entries (the TS signature's
/// reuse point), otherwise allocates. Returns the list holding the angles.
List<double> spreadAngles(
  double baseAngle,
  int seq,
  int salt, [
  List<double>? out,
]) {
  final rng = mulberry32(shotSeed(seq, salt));
  final angles = (out != null && out.length >= pellets)
      ? out
      : List<double>.filled(pellets, 0.0);
  for (var i = 0; i < pellets; i++) {
    angles[i] = baseAngle + (rng() - 0.5) * spreadRad;
  }
  return angles;
}
