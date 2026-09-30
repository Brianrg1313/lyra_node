/// A refusal by an engine rule, with the stable [code] its spec names (`session.md`,
/// `protocol-v1.md` §8) and the fields that code carries ([data]).
///
/// It carries no message: the network layer (phase 3) writes it in the company language when it
/// turns this into an `RpcError`.
final class EngineFailure implements Exception {
  const EngineFailure(this.code, [this.data = const {}]);

  final String code;
  final Map<String, Object?> data;

  @override
  String toString() => "EngineFailure($code${data.isEmpty ? "" : ", $data"})";
}
