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

  const Message({
    this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.readAt,
  });

  Map<String, dynamic> toFirestoreMap() => {
    'senderId': senderId,
    'text': text,
    'createdAt': Timestamp.fromDate(createdAt),
    if (readAt != null) 'readAt': Timestamp.fromDate(readAt!),
  };

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
