import 'package:cloud_firestore/cloud_firestore.dart';

/// A single chat message in a conversation.
class Message {
  /// Firestore document ID (null before insertion).
  final String? id;

  /// The offline ID of the sender.
  final String senderId;

  /// The message text.
  final String text;

  /// When the message was sent.
  final DateTime createdAt;

  /// When the message was read by the recipient (null if unread).
  final DateTime? readAt;

  /// Whether the message is still stuck in the local offline cache (Ghost Queue).
  /// 'pending', 'sent', or 'received'
  final String status;

  const Message({
    this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.readAt,
    this.status = 'sent', // Defaults to sent unless flagged otherwise
  });

  Map<String, dynamic> toMap(String conversationId) => {
    'id': id,
    'conversation_id': conversationId,
    'sender_id': senderId,
    'text': text,
    'created_at': createdAt.toIso8601String(),
    if (readAt != null) 'read_at': readAt!.toIso8601String(),
    'status': status,
  };

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String?,
      senderId: map['sender_id'] as String,
      text: map['text'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      readAt: map['read_at'] != null
          ? DateTime.parse(map['read_at'] as String)
          : null,
      status: map['status'] as String? ?? 'sent',
    );
  }

  Map<String, dynamic> toFirestoreMap() => {
    'senderId': senderId,
    'text': text,
    'createdAt': Timestamp.fromDate(createdAt),
    if (readAt != null) 'readAt': Timestamp.fromDate(readAt!),
  };

  Message copyWith({
    String? id,
    String? senderId,
    String? text,
    DateTime? createdAt,
    DateTime? readAt,
    String? status,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      readAt: readAt ?? this.readAt,
      status: status ?? this.status,
    );
  }

  static DateTime _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is int) {
      // Treat as epoch milliseconds if large enough, otherwise seconds.
      final millis = value > 1000000000000 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  factory Message.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? const {};

    final sender = (data['senderId'] ?? data['from'] ?? '').toString();
    final rawText = data['text'] ?? data['message'] ?? data['body'] ?? '';

    return Message(
      id: doc.id,
      senderId: sender,
      text: rawText.toString(),
      createdAt: _parseDate(
        data['createdAt'] ?? data['sentAt'] ?? data['timestamp'],
      ),
      readAt: data['readAt'] != null ? _parseDate(data['readAt']) : null,
    );
  }

  @override
  String toString() =>
      'Message(from=$senderId, text=${text.length > 20 ? '${text.substring(0, 20)}…' : text})';
}
