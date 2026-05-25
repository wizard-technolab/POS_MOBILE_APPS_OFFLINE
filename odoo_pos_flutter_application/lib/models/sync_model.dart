class SyncModel {
  final int synced;
  final int pending;
  final int failed;
  final String lastSynced;

  SyncModel({
    required this.synced,
    required this.pending,
    required this.failed,
    required this.lastSynced,
  });

  factory SyncModel.fromJson(Map<String, dynamic> json) {
    return SyncModel(
      synced: json['synced'] ?? 0,
      pending: json['pending'] ?? 0,
      failed: json['failed'] ?? 0,
      lastSynced: json['last_synced'] ?? 'Never',
    );
  }
}
