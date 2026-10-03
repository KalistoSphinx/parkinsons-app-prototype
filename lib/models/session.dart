class Session {
  final String id;
  final String patientId;
  final String type; // e.g., 'tremor', 'bradykinesia', 'gait'
  final DateTime startTime;
  final DateTime? endTime;

  Session({
    required this.id,
    required this.patientId,
    required this.type,
    required this.startTime,
    this.endTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientId': patientId,
      'type': type,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
    };
  }

  factory Session.fromMap(Map<String, dynamic> map) {
    return Session(
      id: map['id'],
      patientId: map['patientId'],
      type: map['type'],
      startTime: DateTime.parse(map['startTime']),
      endTime: map['endTime'] != null ? DateTime.parse(map['endTime']) : null,
    );
  }

  Session copyWith({
    String? id,
    String? patientId,
    String? type,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return Session(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      type: type ?? this.type,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
}
