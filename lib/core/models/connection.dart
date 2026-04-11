/// Status of a connection between two offline identities.
enum ConnectionStatus {
  pendingOutgoing,
  pendingIncoming,
  accepted,
  blocked,
}

/// Represents a connection (or pending connection) with another offline user.
class Connection {
  /// Auto-incremented DB primary key (null before insertion).
  final int? id;

  /// This device's offline ID.
  final String myOfflineId;

  /// The other party's offline ID (or BLE hash if full ID is unknown).
  final String otherOfflineId;

  /// Current status of the connection.
  final ConnectionStatus status;

  /// When the two devices first encountered each other.
  final DateTime firstMetAt;

  const Connection({
    this.id,
    required this.myOfflineId,
    required this.otherOfflineId,
    required this.status,
    required this.firstMetAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'my_offline_id': myOfflineId,
        'other_offline_id': otherOfflineId,
        'status': status.index,
        'first_met_at': firstMetAt.toIso8601String(),
      };

  factory Connection.fromMap(Map<String, dynamic> map) {
    return Connection(
      id: map['id'] as int?,
      myOfflineId: map['my_offline_id'] as String,
      otherOfflineId: map['other_offline_id'] as String,
      status: ConnectionStatus.values[map['status'] as int],
      firstMetAt: DateTime.parse(map['first_met_at'] as String),
    );
  }

  Connection copyWith({ConnectionStatus? status}) {
    return Connection(
      id: id,
      myOfflineId: myOfflineId,
      otherOfflineId: otherOfflineId,
      status: status ?? this.status,
      firstMetAt: firstMetAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Connection &&
          runtimeType == other.runtimeType &&
          myOfflineId == other.myOfflineId &&
          otherOfflineId == other.otherOfflineId;

  @override
  int get hashCode => Object.hash(myOfflineId, otherOfflineId);

  @override
  String toString() =>
      'Connection(me=$myOfflineId, other=$otherOfflineId, status=$status)';
}
