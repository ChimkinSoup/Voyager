// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $JournalsTableTable extends JournalsTable
    with TableInfo<$JournalsTableTable, JournalsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JournalsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _guidedJournalingMeta = const VerificationMeta(
    'guidedJournaling',
  );
  @override
  late final GeneratedColumn<bool> guidedJournaling = GeneratedColumn<bool>(
    'guided_journaling',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("guided_journaling" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _promptCycleDaysMeta = const VerificationMeta(
    'promptCycleDays',
  );
  @override
  late final GeneratedColumn<int> promptCycleDays = GeneratedColumn<int>(
    'prompt_cycle_days',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(7),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    colorValue,
    guidedJournaling,
    promptCycleDays,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journals_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<JournalsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    }
    if (data.containsKey('guided_journaling')) {
      context.handle(
        _guidedJournalingMeta,
        guidedJournaling.isAcceptableOrUnknown(
          data['guided_journaling']!,
          _guidedJournalingMeta,
        ),
      );
    }
    if (data.containsKey('prompt_cycle_days')) {
      context.handle(
        _promptCycleDaysMeta,
        promptCycleDays.isAcceptableOrUnknown(
          data['prompt_cycle_days']!,
          _promptCycleDaysMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  JournalsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JournalsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      ),
      guidedJournaling: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}guided_journaling'],
      )!,
      promptCycleDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_cycle_days'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $JournalsTableTable createAlias(String alias) {
    return $JournalsTableTable(attachedDatabase, alias);
  }
}

class JournalsTableData extends DataClass
    implements Insertable<JournalsTableData> {
  final String id;
  final String name;
  final int? colorValue;
  final bool guidedJournaling;
  final int promptCycleDays;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const JournalsTableData({
    required this.id,
    required this.name,
    this.colorValue,
    required this.guidedJournaling,
    required this.promptCycleDays,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || colorValue != null) {
      map['color_value'] = Variable<int>(colorValue);
    }
    map['guided_journaling'] = Variable<bool>(guidedJournaling);
    map['prompt_cycle_days'] = Variable<int>(promptCycleDays);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  JournalsTableCompanion toCompanion(bool nullToAbsent) {
    return JournalsTableCompanion(
      id: Value(id),
      name: Value(name),
      colorValue: colorValue == null && nullToAbsent
          ? const Value.absent()
          : Value(colorValue),
      guidedJournaling: Value(guidedJournaling),
      promptCycleDays: Value(promptCycleDays),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory JournalsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JournalsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      colorValue: serializer.fromJson<int?>(json['colorValue']),
      guidedJournaling: serializer.fromJson<bool>(json['guidedJournaling']),
      promptCycleDays: serializer.fromJson<int>(json['promptCycleDays']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'colorValue': serializer.toJson<int?>(colorValue),
      'guidedJournaling': serializer.toJson<bool>(guidedJournaling),
      'promptCycleDays': serializer.toJson<int>(promptCycleDays),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  JournalsTableData copyWith({
    String? id,
    String? name,
    Value<int?> colorValue = const Value.absent(),
    bool? guidedJournaling,
    int? promptCycleDays,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => JournalsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    colorValue: colorValue.present ? colorValue.value : this.colorValue,
    guidedJournaling: guidedJournaling ?? this.guidedJournaling,
    promptCycleDays: promptCycleDays ?? this.promptCycleDays,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  JournalsTableData copyWithCompanion(JournalsTableCompanion data) {
    return JournalsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      guidedJournaling: data.guidedJournaling.present
          ? data.guidedJournaling.value
          : this.guidedJournaling,
      promptCycleDays: data.promptCycleDays.present
          ? data.promptCycleDays.value
          : this.promptCycleDays,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JournalsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('guidedJournaling: $guidedJournaling, ')
          ..write('promptCycleDays: $promptCycleDays, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    colorValue,
    guidedJournaling,
    promptCycleDays,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JournalsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.colorValue == this.colorValue &&
          other.guidedJournaling == this.guidedJournaling &&
          other.promptCycleDays == this.promptCycleDays &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class JournalsTableCompanion extends UpdateCompanion<JournalsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> colorValue;
  final Value<bool> guidedJournaling;
  final Value<int> promptCycleDays;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const JournalsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.guidedJournaling = const Value.absent(),
    this.promptCycleDays = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  JournalsTableCompanion.insert({
    required String id,
    required String name,
    this.colorValue = const Value.absent(),
    this.guidedJournaling = const Value.absent(),
    this.promptCycleDays = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<JournalsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? colorValue,
    Expression<bool>? guidedJournaling,
    Expression<int>? promptCycleDays,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (colorValue != null) 'color_value': colorValue,
      if (guidedJournaling != null) 'guided_journaling': guidedJournaling,
      if (promptCycleDays != null) 'prompt_cycle_days': promptCycleDays,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  JournalsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int?>? colorValue,
    Value<bool>? guidedJournaling,
    Value<int>? promptCycleDays,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return JournalsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      guidedJournaling: guidedJournaling ?? this.guidedJournaling,
      promptCycleDays: promptCycleDays ?? this.promptCycleDays,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (guidedJournaling.present) {
      map['guided_journaling'] = Variable<bool>(guidedJournaling.value);
    }
    if (promptCycleDays.present) {
      map['prompt_cycle_days'] = Variable<int>(promptCycleDays.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JournalsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('guidedJournaling: $guidedJournaling, ')
          ..write('promptCycleDays: $promptCycleDays, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $JournalEntriesTableTable extends JournalEntriesTable
    with TableInfo<$JournalEntriesTableTable, JournalEntriesTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JournalEntriesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _journalIdMeta = const VerificationMeta(
    'journalId',
  );
  @override
  late final GeneratedColumn<String> journalId = GeneratedColumn<String>(
    'journal_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _richBodyJsonMeta = const VerificationMeta(
    'richBodyJson',
  );
  @override
  late final GeneratedColumn<String> richBodyJson = GeneratedColumn<String>(
    'rich_body_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _entryDateMeta = const VerificationMeta(
    'entryDate',
  );
  @override
  late final GeneratedColumn<DateTime> entryDate = GeneratedColumn<DateTime>(
    'entry_date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
    'timestamp',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _moodMeta = const VerificationMeta('mood');
  @override
  late final GeneratedColumn<int> mood = GeneratedColumn<int>(
    'mood',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _quoteIdMeta = const VerificationMeta(
    'quoteId',
  );
  @override
  late final GeneratedColumn<String> quoteId = GeneratedColumn<String>(
    'quote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _customQuoteMeta = const VerificationMeta(
    'customQuote',
  );
  @override
  late final GeneratedColumn<String> customQuote = GeneratedColumn<String>(
    'custom_quote',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherIconMeta = const VerificationMeta(
    'weatherIcon',
  );
  @override
  late final GeneratedColumn<String> weatherIcon = GeneratedColumn<String>(
    'weather_icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _guidedPromptMeta = const VerificationMeta(
    'guidedPrompt',
  );
  @override
  late final GeneratedColumn<String> guidedPrompt = GeneratedColumn<String>(
    'guided_prompt',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    journalId,
    title,
    body,
    richBodyJson,
    entryDate,
    timestamp,
    tagsJson,
    mood,
    quoteId,
    customQuote,
    weatherIcon,
    guidedPrompt,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journal_entries_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<JournalEntriesTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('journal_id')) {
      context.handle(
        _journalIdMeta,
        journalId.isAcceptableOrUnknown(data['journal_id']!, _journalIdMeta),
      );
    } else if (isInserting) {
      context.missing(_journalIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('rich_body_json')) {
      context.handle(
        _richBodyJsonMeta,
        richBodyJson.isAcceptableOrUnknown(
          data['rich_body_json']!,
          _richBodyJsonMeta,
        ),
      );
    }
    if (data.containsKey('entry_date')) {
      context.handle(
        _entryDateMeta,
        entryDate.isAcceptableOrUnknown(data['entry_date']!, _entryDateMeta),
      );
    } else if (isInserting) {
      context.missing(_entryDateMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    if (data.containsKey('mood')) {
      context.handle(
        _moodMeta,
        mood.isAcceptableOrUnknown(data['mood']!, _moodMeta),
      );
    }
    if (data.containsKey('quote_id')) {
      context.handle(
        _quoteIdMeta,
        quoteId.isAcceptableOrUnknown(data['quote_id']!, _quoteIdMeta),
      );
    }
    if (data.containsKey('custom_quote')) {
      context.handle(
        _customQuoteMeta,
        customQuote.isAcceptableOrUnknown(
          data['custom_quote']!,
          _customQuoteMeta,
        ),
      );
    }
    if (data.containsKey('weather_icon')) {
      context.handle(
        _weatherIconMeta,
        weatherIcon.isAcceptableOrUnknown(
          data['weather_icon']!,
          _weatherIconMeta,
        ),
      );
    }
    if (data.containsKey('guided_prompt')) {
      context.handle(
        _guidedPromptMeta,
        guidedPrompt.isAcceptableOrUnknown(
          data['guided_prompt']!,
          _guidedPromptMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  JournalEntriesTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JournalEntriesTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      journalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}journal_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      richBodyJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rich_body_json'],
      ),
      entryDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}entry_date'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}timestamp'],
      ),
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      mood: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mood'],
      ),
      quoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quote_id'],
      ),
      customQuote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_quote'],
      ),
      weatherIcon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}weather_icon'],
      ),
      guidedPrompt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}guided_prompt'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $JournalEntriesTableTable createAlias(String alias) {
    return $JournalEntriesTableTable(attachedDatabase, alias);
  }
}

class JournalEntriesTableData extends DataClass
    implements Insertable<JournalEntriesTableData> {
  final String id;
  final String journalId;
  final String title;
  final String body;
  final String? richBodyJson;
  final DateTime entryDate;
  final DateTime? timestamp;
  final String tagsJson;
  final int? mood;
  final String? quoteId;
  final String? customQuote;
  final String? weatherIcon;
  final String? guidedPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const JournalEntriesTableData({
    required this.id,
    required this.journalId,
    required this.title,
    required this.body,
    this.richBodyJson,
    required this.entryDate,
    this.timestamp,
    required this.tagsJson,
    this.mood,
    this.quoteId,
    this.customQuote,
    this.weatherIcon,
    this.guidedPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['journal_id'] = Variable<String>(journalId);
    map['title'] = Variable<String>(title);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || richBodyJson != null) {
      map['rich_body_json'] = Variable<String>(richBodyJson);
    }
    map['entry_date'] = Variable<DateTime>(entryDate);
    if (!nullToAbsent || timestamp != null) {
      map['timestamp'] = Variable<DateTime>(timestamp);
    }
    map['tags_json'] = Variable<String>(tagsJson);
    if (!nullToAbsent || mood != null) {
      map['mood'] = Variable<int>(mood);
    }
    if (!nullToAbsent || quoteId != null) {
      map['quote_id'] = Variable<String>(quoteId);
    }
    if (!nullToAbsent || customQuote != null) {
      map['custom_quote'] = Variable<String>(customQuote);
    }
    if (!nullToAbsent || weatherIcon != null) {
      map['weather_icon'] = Variable<String>(weatherIcon);
    }
    if (!nullToAbsent || guidedPrompt != null) {
      map['guided_prompt'] = Variable<String>(guidedPrompt);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  JournalEntriesTableCompanion toCompanion(bool nullToAbsent) {
    return JournalEntriesTableCompanion(
      id: Value(id),
      journalId: Value(journalId),
      title: Value(title),
      body: Value(body),
      richBodyJson: richBodyJson == null && nullToAbsent
          ? const Value.absent()
          : Value(richBodyJson),
      entryDate: Value(entryDate),
      timestamp: timestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(timestamp),
      tagsJson: Value(tagsJson),
      mood: mood == null && nullToAbsent ? const Value.absent() : Value(mood),
      quoteId: quoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(quoteId),
      customQuote: customQuote == null && nullToAbsent
          ? const Value.absent()
          : Value(customQuote),
      weatherIcon: weatherIcon == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherIcon),
      guidedPrompt: guidedPrompt == null && nullToAbsent
          ? const Value.absent()
          : Value(guidedPrompt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory JournalEntriesTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JournalEntriesTableData(
      id: serializer.fromJson<String>(json['id']),
      journalId: serializer.fromJson<String>(json['journalId']),
      title: serializer.fromJson<String>(json['title']),
      body: serializer.fromJson<String>(json['body']),
      richBodyJson: serializer.fromJson<String?>(json['richBodyJson']),
      entryDate: serializer.fromJson<DateTime>(json['entryDate']),
      timestamp: serializer.fromJson<DateTime?>(json['timestamp']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      mood: serializer.fromJson<int?>(json['mood']),
      quoteId: serializer.fromJson<String?>(json['quoteId']),
      customQuote: serializer.fromJson<String?>(json['customQuote']),
      weatherIcon: serializer.fromJson<String?>(json['weatherIcon']),
      guidedPrompt: serializer.fromJson<String?>(json['guidedPrompt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'journalId': serializer.toJson<String>(journalId),
      'title': serializer.toJson<String>(title),
      'body': serializer.toJson<String>(body),
      'richBodyJson': serializer.toJson<String?>(richBodyJson),
      'entryDate': serializer.toJson<DateTime>(entryDate),
      'timestamp': serializer.toJson<DateTime?>(timestamp),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'mood': serializer.toJson<int?>(mood),
      'quoteId': serializer.toJson<String?>(quoteId),
      'customQuote': serializer.toJson<String?>(customQuote),
      'weatherIcon': serializer.toJson<String?>(weatherIcon),
      'guidedPrompt': serializer.toJson<String?>(guidedPrompt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  JournalEntriesTableData copyWith({
    String? id,
    String? journalId,
    String? title,
    String? body,
    Value<String?> richBodyJson = const Value.absent(),
    DateTime? entryDate,
    Value<DateTime?> timestamp = const Value.absent(),
    String? tagsJson,
    Value<int?> mood = const Value.absent(),
    Value<String?> quoteId = const Value.absent(),
    Value<String?> customQuote = const Value.absent(),
    Value<String?> weatherIcon = const Value.absent(),
    Value<String?> guidedPrompt = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => JournalEntriesTableData(
    id: id ?? this.id,
    journalId: journalId ?? this.journalId,
    title: title ?? this.title,
    body: body ?? this.body,
    richBodyJson: richBodyJson.present ? richBodyJson.value : this.richBodyJson,
    entryDate: entryDate ?? this.entryDate,
    timestamp: timestamp.present ? timestamp.value : this.timestamp,
    tagsJson: tagsJson ?? this.tagsJson,
    mood: mood.present ? mood.value : this.mood,
    quoteId: quoteId.present ? quoteId.value : this.quoteId,
    customQuote: customQuote.present ? customQuote.value : this.customQuote,
    weatherIcon: weatherIcon.present ? weatherIcon.value : this.weatherIcon,
    guidedPrompt: guidedPrompt.present ? guidedPrompt.value : this.guidedPrompt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  JournalEntriesTableData copyWithCompanion(JournalEntriesTableCompanion data) {
    return JournalEntriesTableData(
      id: data.id.present ? data.id.value : this.id,
      journalId: data.journalId.present ? data.journalId.value : this.journalId,
      title: data.title.present ? data.title.value : this.title,
      body: data.body.present ? data.body.value : this.body,
      richBodyJson: data.richBodyJson.present
          ? data.richBodyJson.value
          : this.richBodyJson,
      entryDate: data.entryDate.present ? data.entryDate.value : this.entryDate,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      mood: data.mood.present ? data.mood.value : this.mood,
      quoteId: data.quoteId.present ? data.quoteId.value : this.quoteId,
      customQuote: data.customQuote.present
          ? data.customQuote.value
          : this.customQuote,
      weatherIcon: data.weatherIcon.present
          ? data.weatherIcon.value
          : this.weatherIcon,
      guidedPrompt: data.guidedPrompt.present
          ? data.guidedPrompt.value
          : this.guidedPrompt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JournalEntriesTableData(')
          ..write('id: $id, ')
          ..write('journalId: $journalId, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('richBodyJson: $richBodyJson, ')
          ..write('entryDate: $entryDate, ')
          ..write('timestamp: $timestamp, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('mood: $mood, ')
          ..write('quoteId: $quoteId, ')
          ..write('customQuote: $customQuote, ')
          ..write('weatherIcon: $weatherIcon, ')
          ..write('guidedPrompt: $guidedPrompt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    journalId,
    title,
    body,
    richBodyJson,
    entryDate,
    timestamp,
    tagsJson,
    mood,
    quoteId,
    customQuote,
    weatherIcon,
    guidedPrompt,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JournalEntriesTableData &&
          other.id == this.id &&
          other.journalId == this.journalId &&
          other.title == this.title &&
          other.body == this.body &&
          other.richBodyJson == this.richBodyJson &&
          other.entryDate == this.entryDate &&
          other.timestamp == this.timestamp &&
          other.tagsJson == this.tagsJson &&
          other.mood == this.mood &&
          other.quoteId == this.quoteId &&
          other.customQuote == this.customQuote &&
          other.weatherIcon == this.weatherIcon &&
          other.guidedPrompt == this.guidedPrompt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class JournalEntriesTableCompanion
    extends UpdateCompanion<JournalEntriesTableData> {
  final Value<String> id;
  final Value<String> journalId;
  final Value<String> title;
  final Value<String> body;
  final Value<String?> richBodyJson;
  final Value<DateTime> entryDate;
  final Value<DateTime?> timestamp;
  final Value<String> tagsJson;
  final Value<int?> mood;
  final Value<String?> quoteId;
  final Value<String?> customQuote;
  final Value<String?> weatherIcon;
  final Value<String?> guidedPrompt;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const JournalEntriesTableCompanion({
    this.id = const Value.absent(),
    this.journalId = const Value.absent(),
    this.title = const Value.absent(),
    this.body = const Value.absent(),
    this.richBodyJson = const Value.absent(),
    this.entryDate = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.mood = const Value.absent(),
    this.quoteId = const Value.absent(),
    this.customQuote = const Value.absent(),
    this.weatherIcon = const Value.absent(),
    this.guidedPrompt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  JournalEntriesTableCompanion.insert({
    required String id,
    required String journalId,
    required String title,
    required String body,
    this.richBodyJson = const Value.absent(),
    required DateTime entryDate,
    this.timestamp = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.mood = const Value.absent(),
    this.quoteId = const Value.absent(),
    this.customQuote = const Value.absent(),
    this.weatherIcon = const Value.absent(),
    this.guidedPrompt = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       journalId = Value(journalId),
       title = Value(title),
       body = Value(body),
       entryDate = Value(entryDate),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<JournalEntriesTableData> custom({
    Expression<String>? id,
    Expression<String>? journalId,
    Expression<String>? title,
    Expression<String>? body,
    Expression<String>? richBodyJson,
    Expression<DateTime>? entryDate,
    Expression<DateTime>? timestamp,
    Expression<String>? tagsJson,
    Expression<int>? mood,
    Expression<String>? quoteId,
    Expression<String>? customQuote,
    Expression<String>? weatherIcon,
    Expression<String>? guidedPrompt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (journalId != null) 'journal_id': journalId,
      if (title != null) 'title': title,
      if (body != null) 'body': body,
      if (richBodyJson != null) 'rich_body_json': richBodyJson,
      if (entryDate != null) 'entry_date': entryDate,
      if (timestamp != null) 'timestamp': timestamp,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (mood != null) 'mood': mood,
      if (quoteId != null) 'quote_id': quoteId,
      if (customQuote != null) 'custom_quote': customQuote,
      if (weatherIcon != null) 'weather_icon': weatherIcon,
      if (guidedPrompt != null) 'guided_prompt': guidedPrompt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  JournalEntriesTableCompanion copyWith({
    Value<String>? id,
    Value<String>? journalId,
    Value<String>? title,
    Value<String>? body,
    Value<String?>? richBodyJson,
    Value<DateTime>? entryDate,
    Value<DateTime?>? timestamp,
    Value<String>? tagsJson,
    Value<int?>? mood,
    Value<String?>? quoteId,
    Value<String?>? customQuote,
    Value<String?>? weatherIcon,
    Value<String?>? guidedPrompt,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return JournalEntriesTableCompanion(
      id: id ?? this.id,
      journalId: journalId ?? this.journalId,
      title: title ?? this.title,
      body: body ?? this.body,
      richBodyJson: richBodyJson ?? this.richBodyJson,
      entryDate: entryDate ?? this.entryDate,
      timestamp: timestamp ?? this.timestamp,
      tagsJson: tagsJson ?? this.tagsJson,
      mood: mood ?? this.mood,
      quoteId: quoteId ?? this.quoteId,
      customQuote: customQuote ?? this.customQuote,
      weatherIcon: weatherIcon ?? this.weatherIcon,
      guidedPrompt: guidedPrompt ?? this.guidedPrompt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (journalId.present) {
      map['journal_id'] = Variable<String>(journalId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (richBodyJson.present) {
      map['rich_body_json'] = Variable<String>(richBodyJson.value);
    }
    if (entryDate.present) {
      map['entry_date'] = Variable<DateTime>(entryDate.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (mood.present) {
      map['mood'] = Variable<int>(mood.value);
    }
    if (quoteId.present) {
      map['quote_id'] = Variable<String>(quoteId.value);
    }
    if (customQuote.present) {
      map['custom_quote'] = Variable<String>(customQuote.value);
    }
    if (weatherIcon.present) {
      map['weather_icon'] = Variable<String>(weatherIcon.value);
    }
    if (guidedPrompt.present) {
      map['guided_prompt'] = Variable<String>(guidedPrompt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JournalEntriesTableCompanion(')
          ..write('id: $id, ')
          ..write('journalId: $journalId, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('richBodyJson: $richBodyJson, ')
          ..write('entryDate: $entryDate, ')
          ..write('timestamp: $timestamp, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('mood: $mood, ')
          ..write('quoteId: $quoteId, ')
          ..write('customQuote: $customQuote, ')
          ..write('weatherIcon: $weatherIcon, ')
          ..write('guidedPrompt: $guidedPrompt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TodoListsTableTable extends TodoListsTable
    with TableInfo<$TodoListsTableTable, TodoListsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TodoListsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    colorValue,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'todo_lists_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TodoListsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TodoListsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TodoListsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $TodoListsTableTable createAlias(String alias) {
    return $TodoListsTableTable(attachedDatabase, alias);
  }
}

class TodoListsTableData extends DataClass
    implements Insertable<TodoListsTableData> {
  final String id;
  final String name;
  final int? colorValue;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const TodoListsTableData({
    required this.id,
    required this.name,
    this.colorValue,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || colorValue != null) {
      map['color_value'] = Variable<int>(colorValue);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  TodoListsTableCompanion toCompanion(bool nullToAbsent) {
    return TodoListsTableCompanion(
      id: Value(id),
      name: Value(name),
      colorValue: colorValue == null && nullToAbsent
          ? const Value.absent()
          : Value(colorValue),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory TodoListsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TodoListsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      colorValue: serializer.fromJson<int?>(json['colorValue']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'colorValue': serializer.toJson<int?>(colorValue),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  TodoListsTableData copyWith({
    String? id,
    String? name,
    Value<int?> colorValue = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => TodoListsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    colorValue: colorValue.present ? colorValue.value : this.colorValue,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  TodoListsTableData copyWithCompanion(TodoListsTableCompanion data) {
    return TodoListsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TodoListsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, colorValue, createdAt, updatedAt, deletedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TodoListsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.colorValue == this.colorValue &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class TodoListsTableCompanion extends UpdateCompanion<TodoListsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> colorValue;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const TodoListsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TodoListsTableCompanion.insert({
    required String id,
    required String name,
    this.colorValue = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TodoListsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? colorValue,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (colorValue != null) 'color_value': colorValue,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TodoListsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int?>? colorValue,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return TodoListsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TodoListsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TodoTasksTableTable extends TodoTasksTable
    with TableInfo<$TodoTasksTableTable, TodoTasksTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TodoTasksTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  @override
  late final GeneratedColumn<String> listId = GeneratedColumn<String>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentTaskIdMeta = const VerificationMeta(
    'parentTaskId',
  );
  @override
  late final GeneratedColumn<String> parentTaskId = GeneratedColumn<String>(
    'parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueDateMeta = const VerificationMeta(
    'dueDate',
  );
  @override
  late final GeneratedColumn<DateTime> dueDate = GeneratedColumn<DateTime>(
    'due_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completedMeta = const VerificationMeta(
    'completed',
  );
  @override
  late final GeneratedColumn<bool> completed = GeneratedColumn<bool>(
    'completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _starredMeta = const VerificationMeta(
    'starred',
  );
  @override
  late final GeneratedColumn<bool> starred = GeneratedColumn<bool>(
    'starred',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("starred" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _preStarSortOrderMeta = const VerificationMeta(
    'preStarSortOrder',
  );
  @override
  late final GeneratedColumn<int> preStarSortOrder = GeneratedColumn<int>(
    'pre_star_sort_order',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    listId,
    parentTaskId,
    title,
    notes,
    dueDate,
    completed,
    starred,
    sortOrder,
    preStarSortOrder,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'todo_tasks_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TodoTasksTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('parent_task_id')) {
      context.handle(
        _parentTaskIdMeta,
        parentTaskId.isAcceptableOrUnknown(
          data['parent_task_id']!,
          _parentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('due_date')) {
      context.handle(
        _dueDateMeta,
        dueDate.isAcceptableOrUnknown(data['due_date']!, _dueDateMeta),
      );
    }
    if (data.containsKey('completed')) {
      context.handle(
        _completedMeta,
        completed.isAcceptableOrUnknown(data['completed']!, _completedMeta),
      );
    }
    if (data.containsKey('starred')) {
      context.handle(
        _starredMeta,
        starred.isAcceptableOrUnknown(data['starred']!, _starredMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('pre_star_sort_order')) {
      context.handle(
        _preStarSortOrderMeta,
        preStarSortOrder.isAcceptableOrUnknown(
          data['pre_star_sort_order']!,
          _preStarSortOrderMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TodoTasksTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TodoTasksTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_id'],
      )!,
      parentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_task_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      dueDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}due_date'],
      ),
      completed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}completed'],
      )!,
      starred: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}starred'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      preStarSortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pre_star_sort_order'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $TodoTasksTableTable createAlias(String alias) {
    return $TodoTasksTableTable(attachedDatabase, alias);
  }
}

class TodoTasksTableData extends DataClass
    implements Insertable<TodoTasksTableData> {
  final String id;
  final String listId;
  final String? parentTaskId;
  final String title;
  final String? notes;
  final DateTime? dueDate;
  final bool completed;
  final bool starred;
  final int sortOrder;
  final int? preStarSortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const TodoTasksTableData({
    required this.id,
    required this.listId,
    this.parentTaskId,
    required this.title,
    this.notes,
    this.dueDate,
    required this.completed,
    required this.starred,
    required this.sortOrder,
    this.preStarSortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['list_id'] = Variable<String>(listId);
    if (!nullToAbsent || parentTaskId != null) {
      map['parent_task_id'] = Variable<String>(parentTaskId);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || dueDate != null) {
      map['due_date'] = Variable<DateTime>(dueDate);
    }
    map['completed'] = Variable<bool>(completed);
    map['starred'] = Variable<bool>(starred);
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || preStarSortOrder != null) {
      map['pre_star_sort_order'] = Variable<int>(preStarSortOrder);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  TodoTasksTableCompanion toCompanion(bool nullToAbsent) {
    return TodoTasksTableCompanion(
      id: Value(id),
      listId: Value(listId),
      parentTaskId: parentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentTaskId),
      title: Value(title),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      dueDate: dueDate == null && nullToAbsent
          ? const Value.absent()
          : Value(dueDate),
      completed: Value(completed),
      starred: Value(starred),
      sortOrder: Value(sortOrder),
      preStarSortOrder: preStarSortOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(preStarSortOrder),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory TodoTasksTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TodoTasksTableData(
      id: serializer.fromJson<String>(json['id']),
      listId: serializer.fromJson<String>(json['listId']),
      parentTaskId: serializer.fromJson<String?>(json['parentTaskId']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      dueDate: serializer.fromJson<DateTime?>(json['dueDate']),
      completed: serializer.fromJson<bool>(json['completed']),
      starred: serializer.fromJson<bool>(json['starred']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      preStarSortOrder: serializer.fromJson<int?>(json['preStarSortOrder']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'listId': serializer.toJson<String>(listId),
      'parentTaskId': serializer.toJson<String?>(parentTaskId),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String?>(notes),
      'dueDate': serializer.toJson<DateTime?>(dueDate),
      'completed': serializer.toJson<bool>(completed),
      'starred': serializer.toJson<bool>(starred),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'preStarSortOrder': serializer.toJson<int?>(preStarSortOrder),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  TodoTasksTableData copyWith({
    String? id,
    String? listId,
    Value<String?> parentTaskId = const Value.absent(),
    String? title,
    Value<String?> notes = const Value.absent(),
    Value<DateTime?> dueDate = const Value.absent(),
    bool? completed,
    bool? starred,
    int? sortOrder,
    Value<int?> preStarSortOrder = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => TodoTasksTableData(
    id: id ?? this.id,
    listId: listId ?? this.listId,
    parentTaskId: parentTaskId.present ? parentTaskId.value : this.parentTaskId,
    title: title ?? this.title,
    notes: notes.present ? notes.value : this.notes,
    dueDate: dueDate.present ? dueDate.value : this.dueDate,
    completed: completed ?? this.completed,
    starred: starred ?? this.starred,
    sortOrder: sortOrder ?? this.sortOrder,
    preStarSortOrder: preStarSortOrder.present
        ? preStarSortOrder.value
        : this.preStarSortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  TodoTasksTableData copyWithCompanion(TodoTasksTableCompanion data) {
    return TodoTasksTableData(
      id: data.id.present ? data.id.value : this.id,
      listId: data.listId.present ? data.listId.value : this.listId,
      parentTaskId: data.parentTaskId.present
          ? data.parentTaskId.value
          : this.parentTaskId,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      dueDate: data.dueDate.present ? data.dueDate.value : this.dueDate,
      completed: data.completed.present ? data.completed.value : this.completed,
      starred: data.starred.present ? data.starred.value : this.starred,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      preStarSortOrder: data.preStarSortOrder.present
          ? data.preStarSortOrder.value
          : this.preStarSortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TodoTasksTableData(')
          ..write('id: $id, ')
          ..write('listId: $listId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('dueDate: $dueDate, ')
          ..write('completed: $completed, ')
          ..write('starred: $starred, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('preStarSortOrder: $preStarSortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    listId,
    parentTaskId,
    title,
    notes,
    dueDate,
    completed,
    starred,
    sortOrder,
    preStarSortOrder,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TodoTasksTableData &&
          other.id == this.id &&
          other.listId == this.listId &&
          other.parentTaskId == this.parentTaskId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.dueDate == this.dueDate &&
          other.completed == this.completed &&
          other.starred == this.starred &&
          other.sortOrder == this.sortOrder &&
          other.preStarSortOrder == this.preStarSortOrder &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class TodoTasksTableCompanion extends UpdateCompanion<TodoTasksTableData> {
  final Value<String> id;
  final Value<String> listId;
  final Value<String?> parentTaskId;
  final Value<String> title;
  final Value<String?> notes;
  final Value<DateTime?> dueDate;
  final Value<bool> completed;
  final Value<bool> starred;
  final Value<int> sortOrder;
  final Value<int?> preStarSortOrder;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const TodoTasksTableCompanion({
    this.id = const Value.absent(),
    this.listId = const Value.absent(),
    this.parentTaskId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.completed = const Value.absent(),
    this.starred = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.preStarSortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TodoTasksTableCompanion.insert({
    required String id,
    required String listId,
    this.parentTaskId = const Value.absent(),
    required String title,
    this.notes = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.completed = const Value.absent(),
    this.starred = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.preStarSortOrder = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       listId = Value(listId),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TodoTasksTableData> custom({
    Expression<String>? id,
    Expression<String>? listId,
    Expression<String>? parentTaskId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<DateTime>? dueDate,
    Expression<bool>? completed,
    Expression<bool>? starred,
    Expression<int>? sortOrder,
    Expression<int>? preStarSortOrder,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (listId != null) 'list_id': listId,
      if (parentTaskId != null) 'parent_task_id': parentTaskId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (dueDate != null) 'due_date': dueDate,
      if (completed != null) 'completed': completed,
      if (starred != null) 'starred': starred,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (preStarSortOrder != null) 'pre_star_sort_order': preStarSortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TodoTasksTableCompanion copyWith({
    Value<String>? id,
    Value<String>? listId,
    Value<String?>? parentTaskId,
    Value<String>? title,
    Value<String?>? notes,
    Value<DateTime?>? dueDate,
    Value<bool>? completed,
    Value<bool>? starred,
    Value<int>? sortOrder,
    Value<int?>? preStarSortOrder,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return TodoTasksTableCompanion(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      dueDate: dueDate ?? this.dueDate,
      completed: completed ?? this.completed,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      preStarSortOrder: preStarSortOrder ?? this.preStarSortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (listId.present) {
      map['list_id'] = Variable<String>(listId.value);
    }
    if (parentTaskId.present) {
      map['parent_task_id'] = Variable<String>(parentTaskId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (dueDate.present) {
      map['due_date'] = Variable<DateTime>(dueDate.value);
    }
    if (completed.present) {
      map['completed'] = Variable<bool>(completed.value);
    }
    if (starred.present) {
      map['starred'] = Variable<bool>(starred.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (preStarSortOrder.present) {
      map['pre_star_sort_order'] = Variable<int>(preStarSortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TodoTasksTableCompanion(')
          ..write('id: $id, ')
          ..write('listId: $listId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('dueDate: $dueDate, ')
          ..write('completed: $completed, ')
          ..write('starred: $starred, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('preStarSortOrder: $preStarSortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventsTableTable extends CalendarEventsTable
    with TableInfo<$CalendarEventsTableTable, CalendarEventsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startMeta = const VerificationMeta('start');
  @override
  late final GeneratedColumn<DateTime> start = GeneratedColumn<DateTime>(
    'start',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endMeta = const VerificationMeta('end');
  @override
  late final GeneratedColumn<DateTime> end = GeneratedColumn<DateTime>(
    'end',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isFullDayMeta = const VerificationMeta(
    'isFullDay',
  );
  @override
  late final GeneratedColumn<bool> isFullDay = GeneratedColumn<bool>(
    'is_full_day',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_full_day" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFF7C9EFF),
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('local'),
  );
  static const VerificationMeta _externalIdMeta = const VerificationMeta(
    'externalId',
  );
  @override
  late final GeneratedColumn<String> externalId = GeneratedColumn<String>(
    'external_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    start,
    end,
    isFullDay,
    colorValue,
    notes,
    source,
    externalId,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_events_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEventsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('start')) {
      context.handle(
        _startMeta,
        start.isAcceptableOrUnknown(data['start']!, _startMeta),
      );
    } else if (isInserting) {
      context.missing(_startMeta);
    }
    if (data.containsKey('end')) {
      context.handle(
        _endMeta,
        end.isAcceptableOrUnknown(data['end']!, _endMeta),
      );
    } else if (isInserting) {
      context.missing(_endMeta);
    }
    if (data.containsKey('is_full_day')) {
      context.handle(
        _isFullDayMeta,
        isFullDay.isAcceptableOrUnknown(data['is_full_day']!, _isFullDayMeta),
      );
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalendarEventsTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEventsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      start: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}start'],
      )!,
      end: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}end'],
      )!,
      isFullDay: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_full_day'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $CalendarEventsTableTable createAlias(String alias) {
    return $CalendarEventsTableTable(attachedDatabase, alias);
  }
}

class CalendarEventsTableData extends DataClass
    implements Insertable<CalendarEventsTableData> {
  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool isFullDay;
  final int colorValue;
  final String notes;
  final String source;
  final String? externalId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const CalendarEventsTableData({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.isFullDay,
    required this.colorValue,
    required this.notes,
    required this.source,
    this.externalId,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['start'] = Variable<DateTime>(start);
    map['end'] = Variable<DateTime>(end);
    map['is_full_day'] = Variable<bool>(isFullDay);
    map['color_value'] = Variable<int>(colorValue);
    map['notes'] = Variable<String>(notes);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || externalId != null) {
      map['external_id'] = Variable<String>(externalId);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  CalendarEventsTableCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventsTableCompanion(
      id: Value(id),
      title: Value(title),
      start: Value(start),
      end: Value(end),
      isFullDay: Value(isFullDay),
      colorValue: Value(colorValue),
      notes: Value(notes),
      source: Value(source),
      externalId: externalId == null && nullToAbsent
          ? const Value.absent()
          : Value(externalId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory CalendarEventsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEventsTableData(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      start: serializer.fromJson<DateTime>(json['start']),
      end: serializer.fromJson<DateTime>(json['end']),
      isFullDay: serializer.fromJson<bool>(json['isFullDay']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      notes: serializer.fromJson<String>(json['notes']),
      source: serializer.fromJson<String>(json['source']),
      externalId: serializer.fromJson<String?>(json['externalId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'start': serializer.toJson<DateTime>(start),
      'end': serializer.toJson<DateTime>(end),
      'isFullDay': serializer.toJson<bool>(isFullDay),
      'colorValue': serializer.toJson<int>(colorValue),
      'notes': serializer.toJson<String>(notes),
      'source': serializer.toJson<String>(source),
      'externalId': serializer.toJson<String?>(externalId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  CalendarEventsTableData copyWith({
    String? id,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? isFullDay,
    int? colorValue,
    String? notes,
    String? source,
    Value<String?> externalId = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => CalendarEventsTableData(
    id: id ?? this.id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    isFullDay: isFullDay ?? this.isFullDay,
    colorValue: colorValue ?? this.colorValue,
    notes: notes ?? this.notes,
    source: source ?? this.source,
    externalId: externalId.present ? externalId.value : this.externalId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  CalendarEventsTableData copyWithCompanion(CalendarEventsTableCompanion data) {
    return CalendarEventsTableData(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      isFullDay: data.isFullDay.present ? data.isFullDay.value : this.isFullDay,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      notes: data.notes.present ? data.notes.value : this.notes,
      source: data.source.present ? data.source.value : this.source,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventsTableData(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('isFullDay: $isFullDay, ')
          ..write('colorValue: $colorValue, ')
          ..write('notes: $notes, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    start,
    end,
    isFullDay,
    colorValue,
    notes,
    source,
    externalId,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEventsTableData &&
          other.id == this.id &&
          other.title == this.title &&
          other.start == this.start &&
          other.end == this.end &&
          other.isFullDay == this.isFullDay &&
          other.colorValue == this.colorValue &&
          other.notes == this.notes &&
          other.source == this.source &&
          other.externalId == this.externalId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class CalendarEventsTableCompanion
    extends UpdateCompanion<CalendarEventsTableData> {
  final Value<String> id;
  final Value<String> title;
  final Value<DateTime> start;
  final Value<DateTime> end;
  final Value<bool> isFullDay;
  final Value<int> colorValue;
  final Value<String> notes;
  final Value<String> source;
  final Value<String?> externalId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const CalendarEventsTableCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.isFullDay = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.notes = const Value.absent(),
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventsTableCompanion.insert({
    required String id,
    required String title,
    required DateTime start,
    required DateTime end,
    this.isFullDay = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.notes = const Value.absent(),
    this.source = const Value.absent(),
    this.externalId = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       start = Value(start),
       end = Value(end),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CalendarEventsTableData> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<DateTime>? start,
    Expression<DateTime>? end,
    Expression<bool>? isFullDay,
    Expression<int>? colorValue,
    Expression<String>? notes,
    Expression<String>? source,
    Expression<String>? externalId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
      if (isFullDay != null) 'is_full_day': isFullDay,
      if (colorValue != null) 'color_value': colorValue,
      if (notes != null) 'notes': notes,
      if (source != null) 'source': source,
      if (externalId != null) 'external_id': externalId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<DateTime>? start,
    Value<DateTime>? end,
    Value<bool>? isFullDay,
    Value<int>? colorValue,
    Value<String>? notes,
    Value<String>? source,
    Value<String?>? externalId,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return CalendarEventsTableCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
      isFullDay: isFullDay ?? this.isFullDay,
      colorValue: colorValue ?? this.colorValue,
      notes: notes ?? this.notes,
      source: source ?? this.source,
      externalId: externalId ?? this.externalId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (start.present) {
      map['start'] = Variable<DateTime>(start.value);
    }
    if (end.present) {
      map['end'] = Variable<DateTime>(end.value);
    }
    if (isFullDay.present) {
      map['is_full_day'] = Variable<bool>(isFullDay.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventsTableCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('isFullDay: $isFullDay, ')
          ..write('colorValue: $colorValue, ')
          ..write('notes: $notes, ')
          ..write('source: $source, ')
          ..write('externalId: $externalId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TrackersTableTable extends TrackersTable
    with TableInfo<$TrackersTableTable, TrackersTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrackersTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cadenceMeta = const VerificationMeta(
    'cadence',
  );
  @override
  late final GeneratedColumn<String> cadence = GeneratedColumn<String>(
    'cadence',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFF7C9EFF),
  );
  static const VerificationMeta _showOnCalendarMeta = const VerificationMeta(
    'showOnCalendar',
  );
  @override
  late final GeneratedColumn<bool> showOnCalendar = GeneratedColumn<bool>(
    'show_on_calendar',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show_on_calendar" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _integerCapMeta = const VerificationMeta(
    'integerCap',
  );
  @override
  late final GeneratedColumn<int> integerCap = GeneratedColumn<int>(
    'integer_cap',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _defaultIntMeta = const VerificationMeta(
    'defaultInt',
  );
  @override
  late final GeneratedColumn<int> defaultInt = GeneratedColumn<int>(
    'default_int',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _defaultBoolMeta = const VerificationMeta(
    'defaultBool',
  );
  @override
  late final GeneratedColumn<bool> defaultBool = GeneratedColumn<bool>(
    'default_bool',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("default_bool" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _enumOptionsJsonMeta = const VerificationMeta(
    'enumOptionsJson',
  );
  @override
  late final GeneratedColumn<String> enumOptionsJson = GeneratedColumn<String>(
    'enum_options_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _defaultEnumOptionMeta = const VerificationMeta(
    'defaultEnumOption',
  );
  @override
  late final GeneratedColumn<String> defaultEnumOption =
      GeneratedColumn<String>(
        'default_enum_option',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    type,
    cadence,
    colorValue,
    showOnCalendar,
    integerCap,
    defaultInt,
    defaultBool,
    enumOptionsJson,
    defaultEnumOption,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'trackers_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrackersTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('cadence')) {
      context.handle(
        _cadenceMeta,
        cadence.isAcceptableOrUnknown(data['cadence']!, _cadenceMeta),
      );
    } else if (isInserting) {
      context.missing(_cadenceMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    }
    if (data.containsKey('show_on_calendar')) {
      context.handle(
        _showOnCalendarMeta,
        showOnCalendar.isAcceptableOrUnknown(
          data['show_on_calendar']!,
          _showOnCalendarMeta,
        ),
      );
    }
    if (data.containsKey('integer_cap')) {
      context.handle(
        _integerCapMeta,
        integerCap.isAcceptableOrUnknown(data['integer_cap']!, _integerCapMeta),
      );
    }
    if (data.containsKey('default_int')) {
      context.handle(
        _defaultIntMeta,
        defaultInt.isAcceptableOrUnknown(data['default_int']!, _defaultIntMeta),
      );
    }
    if (data.containsKey('default_bool')) {
      context.handle(
        _defaultBoolMeta,
        defaultBool.isAcceptableOrUnknown(
          data['default_bool']!,
          _defaultBoolMeta,
        ),
      );
    }
    if (data.containsKey('enum_options_json')) {
      context.handle(
        _enumOptionsJsonMeta,
        enumOptionsJson.isAcceptableOrUnknown(
          data['enum_options_json']!,
          _enumOptionsJsonMeta,
        ),
      );
    }
    if (data.containsKey('default_enum_option')) {
      context.handle(
        _defaultEnumOptionMeta,
        defaultEnumOption.isAcceptableOrUnknown(
          data['default_enum_option']!,
          _defaultEnumOptionMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrackersTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackersTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      cadence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cadence'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
      showOnCalendar: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show_on_calendar'],
      )!,
      integerCap: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}integer_cap'],
      ),
      defaultInt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}default_int'],
      )!,
      defaultBool: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}default_bool'],
      )!,
      enumOptionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}enum_options_json'],
      )!,
      defaultEnumOption: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}default_enum_option'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $TrackersTableTable createAlias(String alias) {
    return $TrackersTableTable(attachedDatabase, alias);
  }
}

class TrackersTableData extends DataClass
    implements Insertable<TrackersTableData> {
  final String id;
  final String name;
  final String type;
  final String cadence;
  final int colorValue;
  final bool showOnCalendar;
  final int? integerCap;
  final int defaultInt;
  final bool defaultBool;
  final String enumOptionsJson;
  final String? defaultEnumOption;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const TrackersTableData({
    required this.id,
    required this.name,
    required this.type,
    required this.cadence,
    required this.colorValue,
    required this.showOnCalendar,
    this.integerCap,
    required this.defaultInt,
    required this.defaultBool,
    required this.enumOptionsJson,
    this.defaultEnumOption,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['cadence'] = Variable<String>(cadence);
    map['color_value'] = Variable<int>(colorValue);
    map['show_on_calendar'] = Variable<bool>(showOnCalendar);
    if (!nullToAbsent || integerCap != null) {
      map['integer_cap'] = Variable<int>(integerCap);
    }
    map['default_int'] = Variable<int>(defaultInt);
    map['default_bool'] = Variable<bool>(defaultBool);
    map['enum_options_json'] = Variable<String>(enumOptionsJson);
    if (!nullToAbsent || defaultEnumOption != null) {
      map['default_enum_option'] = Variable<String>(defaultEnumOption);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  TrackersTableCompanion toCompanion(bool nullToAbsent) {
    return TrackersTableCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      cadence: Value(cadence),
      colorValue: Value(colorValue),
      showOnCalendar: Value(showOnCalendar),
      integerCap: integerCap == null && nullToAbsent
          ? const Value.absent()
          : Value(integerCap),
      defaultInt: Value(defaultInt),
      defaultBool: Value(defaultBool),
      enumOptionsJson: Value(enumOptionsJson),
      defaultEnumOption: defaultEnumOption == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultEnumOption),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory TrackersTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackersTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      cadence: serializer.fromJson<String>(json['cadence']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      showOnCalendar: serializer.fromJson<bool>(json['showOnCalendar']),
      integerCap: serializer.fromJson<int?>(json['integerCap']),
      defaultInt: serializer.fromJson<int>(json['defaultInt']),
      defaultBool: serializer.fromJson<bool>(json['defaultBool']),
      enumOptionsJson: serializer.fromJson<String>(json['enumOptionsJson']),
      defaultEnumOption: serializer.fromJson<String?>(
        json['defaultEnumOption'],
      ),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'cadence': serializer.toJson<String>(cadence),
      'colorValue': serializer.toJson<int>(colorValue),
      'showOnCalendar': serializer.toJson<bool>(showOnCalendar),
      'integerCap': serializer.toJson<int?>(integerCap),
      'defaultInt': serializer.toJson<int>(defaultInt),
      'defaultBool': serializer.toJson<bool>(defaultBool),
      'enumOptionsJson': serializer.toJson<String>(enumOptionsJson),
      'defaultEnumOption': serializer.toJson<String?>(defaultEnumOption),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  TrackersTableData copyWith({
    String? id,
    String? name,
    String? type,
    String? cadence,
    int? colorValue,
    bool? showOnCalendar,
    Value<int?> integerCap = const Value.absent(),
    int? defaultInt,
    bool? defaultBool,
    String? enumOptionsJson,
    Value<String?> defaultEnumOption = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => TrackersTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    type: type ?? this.type,
    cadence: cadence ?? this.cadence,
    colorValue: colorValue ?? this.colorValue,
    showOnCalendar: showOnCalendar ?? this.showOnCalendar,
    integerCap: integerCap.present ? integerCap.value : this.integerCap,
    defaultInt: defaultInt ?? this.defaultInt,
    defaultBool: defaultBool ?? this.defaultBool,
    enumOptionsJson: enumOptionsJson ?? this.enumOptionsJson,
    defaultEnumOption: defaultEnumOption.present
        ? defaultEnumOption.value
        : this.defaultEnumOption,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  TrackersTableData copyWithCompanion(TrackersTableCompanion data) {
    return TrackersTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      cadence: data.cadence.present ? data.cadence.value : this.cadence,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      showOnCalendar: data.showOnCalendar.present
          ? data.showOnCalendar.value
          : this.showOnCalendar,
      integerCap: data.integerCap.present
          ? data.integerCap.value
          : this.integerCap,
      defaultInt: data.defaultInt.present
          ? data.defaultInt.value
          : this.defaultInt,
      defaultBool: data.defaultBool.present
          ? data.defaultBool.value
          : this.defaultBool,
      enumOptionsJson: data.enumOptionsJson.present
          ? data.enumOptionsJson.value
          : this.enumOptionsJson,
      defaultEnumOption: data.defaultEnumOption.present
          ? data.defaultEnumOption.value
          : this.defaultEnumOption,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackersTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('cadence: $cadence, ')
          ..write('colorValue: $colorValue, ')
          ..write('showOnCalendar: $showOnCalendar, ')
          ..write('integerCap: $integerCap, ')
          ..write('defaultInt: $defaultInt, ')
          ..write('defaultBool: $defaultBool, ')
          ..write('enumOptionsJson: $enumOptionsJson, ')
          ..write('defaultEnumOption: $defaultEnumOption, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    cadence,
    colorValue,
    showOnCalendar,
    integerCap,
    defaultInt,
    defaultBool,
    enumOptionsJson,
    defaultEnumOption,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackersTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.type == this.type &&
          other.cadence == this.cadence &&
          other.colorValue == this.colorValue &&
          other.showOnCalendar == this.showOnCalendar &&
          other.integerCap == this.integerCap &&
          other.defaultInt == this.defaultInt &&
          other.defaultBool == this.defaultBool &&
          other.enumOptionsJson == this.enumOptionsJson &&
          other.defaultEnumOption == this.defaultEnumOption &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class TrackersTableCompanion extends UpdateCompanion<TrackersTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> type;
  final Value<String> cadence;
  final Value<int> colorValue;
  final Value<bool> showOnCalendar;
  final Value<int?> integerCap;
  final Value<int> defaultInt;
  final Value<bool> defaultBool;
  final Value<String> enumOptionsJson;
  final Value<String?> defaultEnumOption;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const TrackersTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.cadence = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.showOnCalendar = const Value.absent(),
    this.integerCap = const Value.absent(),
    this.defaultInt = const Value.absent(),
    this.defaultBool = const Value.absent(),
    this.enumOptionsJson = const Value.absent(),
    this.defaultEnumOption = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TrackersTableCompanion.insert({
    required String id,
    required String name,
    required String type,
    required String cadence,
    this.colorValue = const Value.absent(),
    this.showOnCalendar = const Value.absent(),
    this.integerCap = const Value.absent(),
    this.defaultInt = const Value.absent(),
    this.defaultBool = const Value.absent(),
    this.enumOptionsJson = const Value.absent(),
    this.defaultEnumOption = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       type = Value(type),
       cadence = Value(cadence),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TrackersTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? cadence,
    Expression<int>? colorValue,
    Expression<bool>? showOnCalendar,
    Expression<int>? integerCap,
    Expression<int>? defaultInt,
    Expression<bool>? defaultBool,
    Expression<String>? enumOptionsJson,
    Expression<String>? defaultEnumOption,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (cadence != null) 'cadence': cadence,
      if (colorValue != null) 'color_value': colorValue,
      if (showOnCalendar != null) 'show_on_calendar': showOnCalendar,
      if (integerCap != null) 'integer_cap': integerCap,
      if (defaultInt != null) 'default_int': defaultInt,
      if (defaultBool != null) 'default_bool': defaultBool,
      if (enumOptionsJson != null) 'enum_options_json': enumOptionsJson,
      if (defaultEnumOption != null) 'default_enum_option': defaultEnumOption,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TrackersTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? type,
    Value<String>? cadence,
    Value<int>? colorValue,
    Value<bool>? showOnCalendar,
    Value<int?>? integerCap,
    Value<int>? defaultInt,
    Value<bool>? defaultBool,
    Value<String>? enumOptionsJson,
    Value<String?>? defaultEnumOption,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return TrackersTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      cadence: cadence ?? this.cadence,
      colorValue: colorValue ?? this.colorValue,
      showOnCalendar: showOnCalendar ?? this.showOnCalendar,
      integerCap: integerCap ?? this.integerCap,
      defaultInt: defaultInt ?? this.defaultInt,
      defaultBool: defaultBool ?? this.defaultBool,
      enumOptionsJson: enumOptionsJson ?? this.enumOptionsJson,
      defaultEnumOption: defaultEnumOption ?? this.defaultEnumOption,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (cadence.present) {
      map['cadence'] = Variable<String>(cadence.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (showOnCalendar.present) {
      map['show_on_calendar'] = Variable<bool>(showOnCalendar.value);
    }
    if (integerCap.present) {
      map['integer_cap'] = Variable<int>(integerCap.value);
    }
    if (defaultInt.present) {
      map['default_int'] = Variable<int>(defaultInt.value);
    }
    if (defaultBool.present) {
      map['default_bool'] = Variable<bool>(defaultBool.value);
    }
    if (enumOptionsJson.present) {
      map['enum_options_json'] = Variable<String>(enumOptionsJson.value);
    }
    if (defaultEnumOption.present) {
      map['default_enum_option'] = Variable<String>(defaultEnumOption.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrackersTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('cadence: $cadence, ')
          ..write('colorValue: $colorValue, ')
          ..write('showOnCalendar: $showOnCalendar, ')
          ..write('integerCap: $integerCap, ')
          ..write('defaultInt: $defaultInt, ')
          ..write('defaultBool: $defaultBool, ')
          ..write('enumOptionsJson: $enumOptionsJson, ')
          ..write('defaultEnumOption: $defaultEnumOption, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TrackerValuesTableTable extends TrackerValuesTable
    with TableInfo<$TrackerValuesTableTable, TrackerValuesTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrackerValuesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trackerIdMeta = const VerificationMeta(
    'trackerId',
  );
  @override
  late final GeneratedColumn<String> trackerId = GeneratedColumn<String>(
    'tracker_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodStartMeta = const VerificationMeta(
    'periodStart',
  );
  @override
  late final GeneratedColumn<DateTime> periodStart = GeneratedColumn<DateTime>(
    'period_start',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _intValueMeta = const VerificationMeta(
    'intValue',
  );
  @override
  late final GeneratedColumn<int> intValue = GeneratedColumn<int>(
    'int_value',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _boolValueMeta = const VerificationMeta(
    'boolValue',
  );
  @override
  late final GeneratedColumn<bool> boolValue = GeneratedColumn<bool>(
    'bool_value',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("bool_value" IN (0, 1))',
    ),
  );
  static const VerificationMeta _enumValueMeta = const VerificationMeta(
    'enumValue',
  );
  @override
  late final GeneratedColumn<String> enumValue = GeneratedColumn<String>(
    'enum_value',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    trackerId,
    periodStart,
    intValue,
    boolValue,
    enumValue,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tracker_values_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrackerValuesTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('tracker_id')) {
      context.handle(
        _trackerIdMeta,
        trackerId.isAcceptableOrUnknown(data['tracker_id']!, _trackerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_trackerIdMeta);
    }
    if (data.containsKey('period_start')) {
      context.handle(
        _periodStartMeta,
        periodStart.isAcceptableOrUnknown(
          data['period_start']!,
          _periodStartMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_periodStartMeta);
    }
    if (data.containsKey('int_value')) {
      context.handle(
        _intValueMeta,
        intValue.isAcceptableOrUnknown(data['int_value']!, _intValueMeta),
      );
    }
    if (data.containsKey('bool_value')) {
      context.handle(
        _boolValueMeta,
        boolValue.isAcceptableOrUnknown(data['bool_value']!, _boolValueMeta),
      );
    }
    if (data.containsKey('enum_value')) {
      context.handle(
        _enumValueMeta,
        enumValue.isAcceptableOrUnknown(data['enum_value']!, _enumValueMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrackerValuesTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackerValuesTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      trackerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tracker_id'],
      )!,
      periodStart: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}period_start'],
      )!,
      intValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}int_value'],
      ),
      boolValue: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}bool_value'],
      ),
      enumValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}enum_value'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $TrackerValuesTableTable createAlias(String alias) {
    return $TrackerValuesTableTable(attachedDatabase, alias);
  }
}

class TrackerValuesTableData extends DataClass
    implements Insertable<TrackerValuesTableData> {
  final String id;
  final String trackerId;
  final DateTime periodStart;
  final int? intValue;
  final bool? boolValue;
  final String? enumValue;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const TrackerValuesTableData({
    required this.id,
    required this.trackerId,
    required this.periodStart,
    this.intValue,
    this.boolValue,
    this.enumValue,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['tracker_id'] = Variable<String>(trackerId);
    map['period_start'] = Variable<DateTime>(periodStart);
    if (!nullToAbsent || intValue != null) {
      map['int_value'] = Variable<int>(intValue);
    }
    if (!nullToAbsent || boolValue != null) {
      map['bool_value'] = Variable<bool>(boolValue);
    }
    if (!nullToAbsent || enumValue != null) {
      map['enum_value'] = Variable<String>(enumValue);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  TrackerValuesTableCompanion toCompanion(bool nullToAbsent) {
    return TrackerValuesTableCompanion(
      id: Value(id),
      trackerId: Value(trackerId),
      periodStart: Value(periodStart),
      intValue: intValue == null && nullToAbsent
          ? const Value.absent()
          : Value(intValue),
      boolValue: boolValue == null && nullToAbsent
          ? const Value.absent()
          : Value(boolValue),
      enumValue: enumValue == null && nullToAbsent
          ? const Value.absent()
          : Value(enumValue),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory TrackerValuesTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackerValuesTableData(
      id: serializer.fromJson<String>(json['id']),
      trackerId: serializer.fromJson<String>(json['trackerId']),
      periodStart: serializer.fromJson<DateTime>(json['periodStart']),
      intValue: serializer.fromJson<int?>(json['intValue']),
      boolValue: serializer.fromJson<bool?>(json['boolValue']),
      enumValue: serializer.fromJson<String?>(json['enumValue']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'trackerId': serializer.toJson<String>(trackerId),
      'periodStart': serializer.toJson<DateTime>(periodStart),
      'intValue': serializer.toJson<int?>(intValue),
      'boolValue': serializer.toJson<bool?>(boolValue),
      'enumValue': serializer.toJson<String?>(enumValue),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  TrackerValuesTableData copyWith({
    String? id,
    String? trackerId,
    DateTime? periodStart,
    Value<int?> intValue = const Value.absent(),
    Value<bool?> boolValue = const Value.absent(),
    Value<String?> enumValue = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => TrackerValuesTableData(
    id: id ?? this.id,
    trackerId: trackerId ?? this.trackerId,
    periodStart: periodStart ?? this.periodStart,
    intValue: intValue.present ? intValue.value : this.intValue,
    boolValue: boolValue.present ? boolValue.value : this.boolValue,
    enumValue: enumValue.present ? enumValue.value : this.enumValue,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  TrackerValuesTableData copyWithCompanion(TrackerValuesTableCompanion data) {
    return TrackerValuesTableData(
      id: data.id.present ? data.id.value : this.id,
      trackerId: data.trackerId.present ? data.trackerId.value : this.trackerId,
      periodStart: data.periodStart.present
          ? data.periodStart.value
          : this.periodStart,
      intValue: data.intValue.present ? data.intValue.value : this.intValue,
      boolValue: data.boolValue.present ? data.boolValue.value : this.boolValue,
      enumValue: data.enumValue.present ? data.enumValue.value : this.enumValue,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackerValuesTableData(')
          ..write('id: $id, ')
          ..write('trackerId: $trackerId, ')
          ..write('periodStart: $periodStart, ')
          ..write('intValue: $intValue, ')
          ..write('boolValue: $boolValue, ')
          ..write('enumValue: $enumValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    trackerId,
    periodStart,
    intValue,
    boolValue,
    enumValue,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackerValuesTableData &&
          other.id == this.id &&
          other.trackerId == this.trackerId &&
          other.periodStart == this.periodStart &&
          other.intValue == this.intValue &&
          other.boolValue == this.boolValue &&
          other.enumValue == this.enumValue &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class TrackerValuesTableCompanion
    extends UpdateCompanion<TrackerValuesTableData> {
  final Value<String> id;
  final Value<String> trackerId;
  final Value<DateTime> periodStart;
  final Value<int?> intValue;
  final Value<bool?> boolValue;
  final Value<String?> enumValue;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const TrackerValuesTableCompanion({
    this.id = const Value.absent(),
    this.trackerId = const Value.absent(),
    this.periodStart = const Value.absent(),
    this.intValue = const Value.absent(),
    this.boolValue = const Value.absent(),
    this.enumValue = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TrackerValuesTableCompanion.insert({
    required String id,
    required String trackerId,
    required DateTime periodStart,
    this.intValue = const Value.absent(),
    this.boolValue = const Value.absent(),
    this.enumValue = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       trackerId = Value(trackerId),
       periodStart = Value(periodStart),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TrackerValuesTableData> custom({
    Expression<String>? id,
    Expression<String>? trackerId,
    Expression<DateTime>? periodStart,
    Expression<int>? intValue,
    Expression<bool>? boolValue,
    Expression<String>? enumValue,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (trackerId != null) 'tracker_id': trackerId,
      if (periodStart != null) 'period_start': periodStart,
      if (intValue != null) 'int_value': intValue,
      if (boolValue != null) 'bool_value': boolValue,
      if (enumValue != null) 'enum_value': enumValue,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TrackerValuesTableCompanion copyWith({
    Value<String>? id,
    Value<String>? trackerId,
    Value<DateTime>? periodStart,
    Value<int?>? intValue,
    Value<bool?>? boolValue,
    Value<String?>? enumValue,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return TrackerValuesTableCompanion(
      id: id ?? this.id,
      trackerId: trackerId ?? this.trackerId,
      periodStart: periodStart ?? this.periodStart,
      intValue: intValue ?? this.intValue,
      boolValue: boolValue ?? this.boolValue,
      enumValue: enumValue ?? this.enumValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (trackerId.present) {
      map['tracker_id'] = Variable<String>(trackerId.value);
    }
    if (periodStart.present) {
      map['period_start'] = Variable<DateTime>(periodStart.value);
    }
    if (intValue.present) {
      map['int_value'] = Variable<int>(intValue.value);
    }
    if (boolValue.present) {
      map['bool_value'] = Variable<bool>(boolValue.value);
    }
    if (enumValue.present) {
      map['enum_value'] = Variable<String>(enumValue.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrackerValuesTableCompanion(')
          ..write('id: $id, ')
          ..write('trackerId: $trackerId, ')
          ..write('periodStart: $periodStart, ')
          ..write('intValue: $intValue, ')
          ..write('boolValue: $boolValue, ')
          ..write('enumValue: $enumValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RankingConfigsTableTable extends RankingConfigsTable
    with TableInfo<$RankingConfigsTableTable, RankingConfigsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RankingConfigsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cadenceMeta = const VerificationMeta(
    'cadence',
  );
  @override
  late final GeneratedColumn<String> cadence = GeneratedColumn<String>(
    'cadence',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maxValueMeta = const VerificationMeta(
    'maxValue',
  );
  @override
  late final GeneratedColumn<int> maxValue = GeneratedColumn<int>(
    'max_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorStartMeta = const VerificationMeta(
    'colorStart',
  );
  @override
  late final GeneratedColumn<int> colorStart = GeneratedColumn<int>(
    'color_start',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFF4CAF50),
  );
  static const VerificationMeta _colorEndMeta = const VerificationMeta(
    'colorEnd',
  );
  @override
  late final GeneratedColumn<int> colorEnd = GeneratedColumn<int>(
    'color_end',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFFF44336),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    cadence,
    maxValue,
    colorStart,
    colorEnd,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ranking_configs_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<RankingConfigsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('cadence')) {
      context.handle(
        _cadenceMeta,
        cadence.isAcceptableOrUnknown(data['cadence']!, _cadenceMeta),
      );
    } else if (isInserting) {
      context.missing(_cadenceMeta);
    }
    if (data.containsKey('max_value')) {
      context.handle(
        _maxValueMeta,
        maxValue.isAcceptableOrUnknown(data['max_value']!, _maxValueMeta),
      );
    } else if (isInserting) {
      context.missing(_maxValueMeta);
    }
    if (data.containsKey('color_start')) {
      context.handle(
        _colorStartMeta,
        colorStart.isAcceptableOrUnknown(data['color_start']!, _colorStartMeta),
      );
    }
    if (data.containsKey('color_end')) {
      context.handle(
        _colorEndMeta,
        colorEnd.isAcceptableOrUnknown(data['color_end']!, _colorEndMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RankingConfigsTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RankingConfigsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      cadence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cadence'],
      )!,
      maxValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}max_value'],
      )!,
      colorStart: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_start'],
      )!,
      colorEnd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_end'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $RankingConfigsTableTable createAlias(String alias) {
    return $RankingConfigsTableTable(attachedDatabase, alias);
  }
}

class RankingConfigsTableData extends DataClass
    implements Insertable<RankingConfigsTableData> {
  final String id;
  final String name;
  final String cadence;
  final int maxValue;
  final int colorStart;
  final int colorEnd;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const RankingConfigsTableData({
    required this.id,
    required this.name,
    required this.cadence,
    required this.maxValue,
    required this.colorStart,
    required this.colorEnd,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['cadence'] = Variable<String>(cadence);
    map['max_value'] = Variable<int>(maxValue);
    map['color_start'] = Variable<int>(colorStart);
    map['color_end'] = Variable<int>(colorEnd);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  RankingConfigsTableCompanion toCompanion(bool nullToAbsent) {
    return RankingConfigsTableCompanion(
      id: Value(id),
      name: Value(name),
      cadence: Value(cadence),
      maxValue: Value(maxValue),
      colorStart: Value(colorStart),
      colorEnd: Value(colorEnd),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory RankingConfigsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RankingConfigsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      cadence: serializer.fromJson<String>(json['cadence']),
      maxValue: serializer.fromJson<int>(json['maxValue']),
      colorStart: serializer.fromJson<int>(json['colorStart']),
      colorEnd: serializer.fromJson<int>(json['colorEnd']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'cadence': serializer.toJson<String>(cadence),
      'maxValue': serializer.toJson<int>(maxValue),
      'colorStart': serializer.toJson<int>(colorStart),
      'colorEnd': serializer.toJson<int>(colorEnd),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  RankingConfigsTableData copyWith({
    String? id,
    String? name,
    String? cadence,
    int? maxValue,
    int? colorStart,
    int? colorEnd,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => RankingConfigsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    cadence: cadence ?? this.cadence,
    maxValue: maxValue ?? this.maxValue,
    colorStart: colorStart ?? this.colorStart,
    colorEnd: colorEnd ?? this.colorEnd,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  RankingConfigsTableData copyWithCompanion(RankingConfigsTableCompanion data) {
    return RankingConfigsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      cadence: data.cadence.present ? data.cadence.value : this.cadence,
      maxValue: data.maxValue.present ? data.maxValue.value : this.maxValue,
      colorStart: data.colorStart.present
          ? data.colorStart.value
          : this.colorStart,
      colorEnd: data.colorEnd.present ? data.colorEnd.value : this.colorEnd,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RankingConfigsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('cadence: $cadence, ')
          ..write('maxValue: $maxValue, ')
          ..write('colorStart: $colorStart, ')
          ..write('colorEnd: $colorEnd, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    cadence,
    maxValue,
    colorStart,
    colorEnd,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RankingConfigsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.cadence == this.cadence &&
          other.maxValue == this.maxValue &&
          other.colorStart == this.colorStart &&
          other.colorEnd == this.colorEnd &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class RankingConfigsTableCompanion
    extends UpdateCompanion<RankingConfigsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> cadence;
  final Value<int> maxValue;
  final Value<int> colorStart;
  final Value<int> colorEnd;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const RankingConfigsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.cadence = const Value.absent(),
    this.maxValue = const Value.absent(),
    this.colorStart = const Value.absent(),
    this.colorEnd = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RankingConfigsTableCompanion.insert({
    required String id,
    required String name,
    required String cadence,
    required int maxValue,
    this.colorStart = const Value.absent(),
    this.colorEnd = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       cadence = Value(cadence),
       maxValue = Value(maxValue),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<RankingConfigsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? cadence,
    Expression<int>? maxValue,
    Expression<int>? colorStart,
    Expression<int>? colorEnd,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (cadence != null) 'cadence': cadence,
      if (maxValue != null) 'max_value': maxValue,
      if (colorStart != null) 'color_start': colorStart,
      if (colorEnd != null) 'color_end': colorEnd,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RankingConfigsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? cadence,
    Value<int>? maxValue,
    Value<int>? colorStart,
    Value<int>? colorEnd,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return RankingConfigsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      cadence: cadence ?? this.cadence,
      maxValue: maxValue ?? this.maxValue,
      colorStart: colorStart ?? this.colorStart,
      colorEnd: colorEnd ?? this.colorEnd,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (cadence.present) {
      map['cadence'] = Variable<String>(cadence.value);
    }
    if (maxValue.present) {
      map['max_value'] = Variable<int>(maxValue.value);
    }
    if (colorStart.present) {
      map['color_start'] = Variable<int>(colorStart.value);
    }
    if (colorEnd.present) {
      map['color_end'] = Variable<int>(colorEnd.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RankingConfigsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('cadence: $cadence, ')
          ..write('maxValue: $maxValue, ')
          ..write('colorStart: $colorStart, ')
          ..write('colorEnd: $colorEnd, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RankingValuesTableTable extends RankingValuesTable
    with TableInfo<$RankingValuesTableTable, RankingValuesTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RankingValuesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _configIdMeta = const VerificationMeta(
    'configId',
  );
  @override
  late final GeneratedColumn<String> configId = GeneratedColumn<String>(
    'config_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodStartMeta = const VerificationMeta(
    'periodStart',
  );
  @override
  late final GeneratedColumn<DateTime> periodStart = GeneratedColumn<DateTime>(
    'period_start',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<int> value = GeneratedColumn<int>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    configId,
    periodStart,
    value,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ranking_values_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<RankingValuesTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('config_id')) {
      context.handle(
        _configIdMeta,
        configId.isAcceptableOrUnknown(data['config_id']!, _configIdMeta),
      );
    } else if (isInserting) {
      context.missing(_configIdMeta);
    }
    if (data.containsKey('period_start')) {
      context.handle(
        _periodStartMeta,
        periodStart.isAcceptableOrUnknown(
          data['period_start']!,
          _periodStartMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_periodStartMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RankingValuesTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RankingValuesTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      configId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_id'],
      )!,
      periodStart: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}period_start'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}value'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $RankingValuesTableTable createAlias(String alias) {
    return $RankingValuesTableTable(attachedDatabase, alias);
  }
}

class RankingValuesTableData extends DataClass
    implements Insertable<RankingValuesTableData> {
  final String id;
  final String configId;
  final DateTime periodStart;
  final int value;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  const RankingValuesTableData({
    required this.id,
    required this.configId,
    required this.periodStart,
    required this.value,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['config_id'] = Variable<String>(configId);
    map['period_start'] = Variable<DateTime>(periodStart);
    map['value'] = Variable<int>(value);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  RankingValuesTableCompanion toCompanion(bool nullToAbsent) {
    return RankingValuesTableCompanion(
      id: Value(id),
      configId: Value(configId),
      periodStart: Value(periodStart),
      value: Value(value),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory RankingValuesTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RankingValuesTableData(
      id: serializer.fromJson<String>(json['id']),
      configId: serializer.fromJson<String>(json['configId']),
      periodStart: serializer.fromJson<DateTime>(json['periodStart']),
      value: serializer.fromJson<int>(json['value']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'configId': serializer.toJson<String>(configId),
      'periodStart': serializer.toJson<DateTime>(periodStart),
      'value': serializer.toJson<int>(value),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  RankingValuesTableData copyWith({
    String? id,
    String? configId,
    DateTime? periodStart,
    int? value,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => RankingValuesTableData(
    id: id ?? this.id,
    configId: configId ?? this.configId,
    periodStart: periodStart ?? this.periodStart,
    value: value ?? this.value,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  RankingValuesTableData copyWithCompanion(RankingValuesTableCompanion data) {
    return RankingValuesTableData(
      id: data.id.present ? data.id.value : this.id,
      configId: data.configId.present ? data.configId.value : this.configId,
      periodStart: data.periodStart.present
          ? data.periodStart.value
          : this.periodStart,
      value: data.value.present ? data.value.value : this.value,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RankingValuesTableData(')
          ..write('id: $id, ')
          ..write('configId: $configId, ')
          ..write('periodStart: $periodStart, ')
          ..write('value: $value, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    configId,
    periodStart,
    value,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RankingValuesTableData &&
          other.id == this.id &&
          other.configId == this.configId &&
          other.periodStart == this.periodStart &&
          other.value == this.value &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class RankingValuesTableCompanion
    extends UpdateCompanion<RankingValuesTableData> {
  final Value<String> id;
  final Value<String> configId;
  final Value<DateTime> periodStart;
  final Value<int> value;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const RankingValuesTableCompanion({
    this.id = const Value.absent(),
    this.configId = const Value.absent(),
    this.periodStart = const Value.absent(),
    this.value = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RankingValuesTableCompanion.insert({
    required String id,
    required String configId,
    required DateTime periodStart,
    required int value,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       configId = Value(configId),
       periodStart = Value(periodStart),
       value = Value(value),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<RankingValuesTableData> custom({
    Expression<String>? id,
    Expression<String>? configId,
    Expression<DateTime>? periodStart,
    Expression<int>? value,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (configId != null) 'config_id': configId,
      if (periodStart != null) 'period_start': periodStart,
      if (value != null) 'value': value,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RankingValuesTableCompanion copyWith({
    Value<String>? id,
    Value<String>? configId,
    Value<DateTime>? periodStart,
    Value<int>? value,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return RankingValuesTableCompanion(
      id: id ?? this.id,
      configId: configId ?? this.configId,
      periodStart: periodStart ?? this.periodStart,
      value: value ?? this.value,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (configId.present) {
      map['config_id'] = Variable<String>(configId.value);
    }
    if (periodStart.present) {
      map['period_start'] = Variable<DateTime>(periodStart.value);
    }
    if (value.present) {
      map['value'] = Variable<int>(value.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RankingValuesTableCompanion(')
          ..write('id: $id, ')
          ..write('configId: $configId, ')
          ..write('periodStart: $periodStart, ')
          ..write('value: $value, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTableTable extends SettingsTable
    with TableInfo<$SettingsTableTable, SettingsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _accentColorMeta = const VerificationMeta(
    'accentColor',
  );
  @override
  late final GeneratedColumn<int> accentColor = GeneratedColumn<int>(
    'accent_color',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFF7C9EFF),
  );
  static const VerificationMeta _weekStartsOnMondayMeta =
      const VerificationMeta('weekStartsOnMonday');
  @override
  late final GeneratedColumn<bool> weekStartsOnMonday = GeneratedColumn<bool>(
    'week_starts_on_monday',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("week_starts_on_monday" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _showQuotesMeta = const VerificationMeta(
    'showQuotes',
  );
  @override
  late final GeneratedColumn<bool> showQuotes = GeneratedColumn<bool>(
    'show_quotes',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show_quotes" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _journalHotkeyMeta = const VerificationMeta(
    'journalHotkey',
  );
  @override
  late final GeneratedColumn<String> journalHotkey = GeneratedColumn<String>(
    'journal_hotkey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(defaultJournalHotkey),
  );
  static const VerificationMeta _todoHotkeyMeta = const VerificationMeta(
    'todoHotkey',
  );
  @override
  late final GeneratedColumn<String> todoHotkey = GeneratedColumn<String>(
    'todo_hotkey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(defaultTodoHotkey),
  );
  static const VerificationMeta _rankingColorStartMeta = const VerificationMeta(
    'rankingColorStart',
  );
  @override
  late final GeneratedColumn<int> rankingColorStart = GeneratedColumn<int>(
    'ranking_color_start',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFF4CAF50),
  );
  static const VerificationMeta _rankingColorEndMeta = const VerificationMeta(
    'rankingColorEnd',
  );
  @override
  late final GeneratedColumn<int> rankingColorEnd = GeneratedColumn<int>(
    'ranking_color_end',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0xFFF44336),
  );
  static const VerificationMeta _timelineModeYearZeroMeta =
      const VerificationMeta('timelineModeYearZero');
  @override
  late final GeneratedColumn<bool> timelineModeYearZero = GeneratedColumn<bool>(
    'timeline_mode_year_zero',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("timeline_mode_year_zero" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _birthYearMeta = const VerificationMeta(
    'birthYear',
  );
  @override
  late final GeneratedColumn<int> birthYear = GeneratedColumn<int>(
    'birth_year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _alertOnPeriodicPromptsMeta =
      const VerificationMeta('alertOnPeriodicPrompts');
  @override
  late final GeneratedColumn<bool> alertOnPeriodicPrompts =
      GeneratedColumn<bool>(
        'alert_on_periodic_prompts',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("alert_on_periodic_prompts" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _alertTimeHourMeta = const VerificationMeta(
    'alertTimeHour',
  );
  @override
  late final GeneratedColumn<int> alertTimeHour = GeneratedColumn<int>(
    'alert_time_hour',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(9),
  );
  static const VerificationMeta _hideCompletedTasksMeta =
      const VerificationMeta('hideCompletedTasks');
  @override
  late final GeneratedColumn<bool> hideCompletedTasks = GeneratedColumn<bool>(
    'hide_completed_tasks',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hide_completed_tasks" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherLocationLabelMeta =
      const VerificationMeta('weatherLocationLabel');
  @override
  late final GeneratedColumn<String> weatherLocationLabel =
      GeneratedColumn<String>(
        'weather_location_label',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _weatherLatMeta = const VerificationMeta(
    'weatherLat',
  );
  @override
  late final GeneratedColumn<double> weatherLat = GeneratedColumn<double>(
    'weather_lat',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherLonMeta = const VerificationMeta(
    'weatherLon',
  );
  @override
  late final GeneratedColumn<double> weatherLon = GeneratedColumn<double>(
    'weather_lon',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherIconMeta = const VerificationMeta(
    'weatherIcon',
  );
  @override
  late final GeneratedColumn<String> weatherIcon = GeneratedColumn<String>(
    'weather_icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherFetchedAtMeta = const VerificationMeta(
    'weatherFetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> weatherFetchedAt =
      GeneratedColumn<DateTime>(
        'weather_fetched_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _weatherConditionCodeMeta =
      const VerificationMeta('weatherConditionCode');
  @override
  late final GeneratedColumn<int> weatherConditionCode = GeneratedColumn<int>(
    'weather_condition_code',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherTempCMeta = const VerificationMeta(
    'weatherTempC',
  );
  @override
  late final GeneratedColumn<double> weatherTempC = GeneratedColumn<double>(
    'weather_temp_c',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherLocationUpdatedAtMeta =
      const VerificationMeta('weatherLocationUpdatedAt');
  @override
  late final GeneratedColumn<DateTime> weatherLocationUpdatedAt =
      GeneratedColumn<DateTime>(
        'weather_location_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _devUseDirectOpenWeatherMeta =
      const VerificationMeta('devUseDirectOpenWeather');
  @override
  late final GeneratedColumn<bool> devUseDirectOpenWeather =
      GeneratedColumn<bool>(
        'dev_use_direct_open_weather',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("dev_use_direct_open_weather" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _devOpenWeatherApiKeyMeta =
      const VerificationMeta('devOpenWeatherApiKey');
  @override
  late final GeneratedColumn<String> devOpenWeatherApiKey =
      GeneratedColumn<String>(
        'dev_open_weather_api_key',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _weatherForecastJsonMeta =
      const VerificationMeta('weatherForecastJson');
  @override
  late final GeneratedColumn<String> weatherForecastJson =
      GeneratedColumn<String>(
        'weather_forecast_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _weatherChartTempColorMeta =
      const VerificationMeta('weatherChartTempColor');
  @override
  late final GeneratedColumn<int> weatherChartTempColor = GeneratedColumn<int>(
    'weather_chart_temp_color',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _weatherChartRainColorMeta =
      const VerificationMeta('weatherChartRainColor');
  @override
  late final GeneratedColumn<int> weatherChartRainColor = GeneratedColumn<int>(
    'weather_chart_rain_color',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorPaletteJsonMeta = const VerificationMeta(
    'colorPaletteJson',
  );
  @override
  late final GeneratedColumn<String> colorPaletteJson = GeneratedColumn<String>(
    'color_palette_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accentColor,
    weekStartsOnMonday,
    showQuotes,
    journalHotkey,
    todoHotkey,
    rankingColorStart,
    rankingColorEnd,
    timelineModeYearZero,
    birthYear,
    alertOnPeriodicPrompts,
    alertTimeHour,
    hideCompletedTasks,
    deviceId,
    weatherLocationLabel,
    weatherLat,
    weatherLon,
    weatherIcon,
    weatherFetchedAt,
    weatherConditionCode,
    weatherTempC,
    weatherLocationUpdatedAt,
    devUseDirectOpenWeather,
    devOpenWeatherApiKey,
    weatherForecastJson,
    weatherChartTempColor,
    weatherChartRainColor,
    colorPaletteJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('accent_color')) {
      context.handle(
        _accentColorMeta,
        accentColor.isAcceptableOrUnknown(
          data['accent_color']!,
          _accentColorMeta,
        ),
      );
    }
    if (data.containsKey('week_starts_on_monday')) {
      context.handle(
        _weekStartsOnMondayMeta,
        weekStartsOnMonday.isAcceptableOrUnknown(
          data['week_starts_on_monday']!,
          _weekStartsOnMondayMeta,
        ),
      );
    }
    if (data.containsKey('show_quotes')) {
      context.handle(
        _showQuotesMeta,
        showQuotes.isAcceptableOrUnknown(data['show_quotes']!, _showQuotesMeta),
      );
    }
    if (data.containsKey('journal_hotkey')) {
      context.handle(
        _journalHotkeyMeta,
        journalHotkey.isAcceptableOrUnknown(
          data['journal_hotkey']!,
          _journalHotkeyMeta,
        ),
      );
    }
    if (data.containsKey('todo_hotkey')) {
      context.handle(
        _todoHotkeyMeta,
        todoHotkey.isAcceptableOrUnknown(data['todo_hotkey']!, _todoHotkeyMeta),
      );
    }
    if (data.containsKey('ranking_color_start')) {
      context.handle(
        _rankingColorStartMeta,
        rankingColorStart.isAcceptableOrUnknown(
          data['ranking_color_start']!,
          _rankingColorStartMeta,
        ),
      );
    }
    if (data.containsKey('ranking_color_end')) {
      context.handle(
        _rankingColorEndMeta,
        rankingColorEnd.isAcceptableOrUnknown(
          data['ranking_color_end']!,
          _rankingColorEndMeta,
        ),
      );
    }
    if (data.containsKey('timeline_mode_year_zero')) {
      context.handle(
        _timelineModeYearZeroMeta,
        timelineModeYearZero.isAcceptableOrUnknown(
          data['timeline_mode_year_zero']!,
          _timelineModeYearZeroMeta,
        ),
      );
    }
    if (data.containsKey('birth_year')) {
      context.handle(
        _birthYearMeta,
        birthYear.isAcceptableOrUnknown(data['birth_year']!, _birthYearMeta),
      );
    }
    if (data.containsKey('alert_on_periodic_prompts')) {
      context.handle(
        _alertOnPeriodicPromptsMeta,
        alertOnPeriodicPrompts.isAcceptableOrUnknown(
          data['alert_on_periodic_prompts']!,
          _alertOnPeriodicPromptsMeta,
        ),
      );
    }
    if (data.containsKey('alert_time_hour')) {
      context.handle(
        _alertTimeHourMeta,
        alertTimeHour.isAcceptableOrUnknown(
          data['alert_time_hour']!,
          _alertTimeHourMeta,
        ),
      );
    }
    if (data.containsKey('hide_completed_tasks')) {
      context.handle(
        _hideCompletedTasksMeta,
        hideCompletedTasks.isAcceptableOrUnknown(
          data['hide_completed_tasks']!,
          _hideCompletedTasksMeta,
        ),
      );
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    }
    if (data.containsKey('weather_location_label')) {
      context.handle(
        _weatherLocationLabelMeta,
        weatherLocationLabel.isAcceptableOrUnknown(
          data['weather_location_label']!,
          _weatherLocationLabelMeta,
        ),
      );
    }
    if (data.containsKey('weather_lat')) {
      context.handle(
        _weatherLatMeta,
        weatherLat.isAcceptableOrUnknown(data['weather_lat']!, _weatherLatMeta),
      );
    }
    if (data.containsKey('weather_lon')) {
      context.handle(
        _weatherLonMeta,
        weatherLon.isAcceptableOrUnknown(data['weather_lon']!, _weatherLonMeta),
      );
    }
    if (data.containsKey('weather_icon')) {
      context.handle(
        _weatherIconMeta,
        weatherIcon.isAcceptableOrUnknown(
          data['weather_icon']!,
          _weatherIconMeta,
        ),
      );
    }
    if (data.containsKey('weather_fetched_at')) {
      context.handle(
        _weatherFetchedAtMeta,
        weatherFetchedAt.isAcceptableOrUnknown(
          data['weather_fetched_at']!,
          _weatherFetchedAtMeta,
        ),
      );
    }
    if (data.containsKey('weather_condition_code')) {
      context.handle(
        _weatherConditionCodeMeta,
        weatherConditionCode.isAcceptableOrUnknown(
          data['weather_condition_code']!,
          _weatherConditionCodeMeta,
        ),
      );
    }
    if (data.containsKey('weather_temp_c')) {
      context.handle(
        _weatherTempCMeta,
        weatherTempC.isAcceptableOrUnknown(
          data['weather_temp_c']!,
          _weatherTempCMeta,
        ),
      );
    }
    if (data.containsKey('weather_location_updated_at')) {
      context.handle(
        _weatherLocationUpdatedAtMeta,
        weatherLocationUpdatedAt.isAcceptableOrUnknown(
          data['weather_location_updated_at']!,
          _weatherLocationUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('dev_use_direct_open_weather')) {
      context.handle(
        _devUseDirectOpenWeatherMeta,
        devUseDirectOpenWeather.isAcceptableOrUnknown(
          data['dev_use_direct_open_weather']!,
          _devUseDirectOpenWeatherMeta,
        ),
      );
    }
    if (data.containsKey('dev_open_weather_api_key')) {
      context.handle(
        _devOpenWeatherApiKeyMeta,
        devOpenWeatherApiKey.isAcceptableOrUnknown(
          data['dev_open_weather_api_key']!,
          _devOpenWeatherApiKeyMeta,
        ),
      );
    }
    if (data.containsKey('weather_forecast_json')) {
      context.handle(
        _weatherForecastJsonMeta,
        weatherForecastJson.isAcceptableOrUnknown(
          data['weather_forecast_json']!,
          _weatherForecastJsonMeta,
        ),
      );
    }
    if (data.containsKey('weather_chart_temp_color')) {
      context.handle(
        _weatherChartTempColorMeta,
        weatherChartTempColor.isAcceptableOrUnknown(
          data['weather_chart_temp_color']!,
          _weatherChartTempColorMeta,
        ),
      );
    }
    if (data.containsKey('weather_chart_rain_color')) {
      context.handle(
        _weatherChartRainColorMeta,
        weatherChartRainColor.isAcceptableOrUnknown(
          data['weather_chart_rain_color']!,
          _weatherChartRainColorMeta,
        ),
      );
    }
    if (data.containsKey('color_palette_json')) {
      context.handle(
        _colorPaletteJsonMeta,
        colorPaletteJson.isAcceptableOrUnknown(
          data['color_palette_json']!,
          _colorPaletteJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SettingsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accentColor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}accent_color'],
      )!,
      weekStartsOnMonday: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}week_starts_on_monday'],
      )!,
      showQuotes: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show_quotes'],
      )!,
      journalHotkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}journal_hotkey'],
      )!,
      todoHotkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}todo_hotkey'],
      )!,
      rankingColorStart: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ranking_color_start'],
      )!,
      rankingColorEnd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ranking_color_end'],
      )!,
      timelineModeYearZero: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}timeline_mode_year_zero'],
      )!,
      birthYear: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}birth_year'],
      ),
      alertOnPeriodicPrompts: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}alert_on_periodic_prompts'],
      )!,
      alertTimeHour: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}alert_time_hour'],
      )!,
      hideCompletedTasks: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hide_completed_tasks'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      ),
      weatherLocationLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}weather_location_label'],
      ),
      weatherLat: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}weather_lat'],
      ),
      weatherLon: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}weather_lon'],
      ),
      weatherIcon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}weather_icon'],
      ),
      weatherFetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}weather_fetched_at'],
      ),
      weatherConditionCode: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weather_condition_code'],
      ),
      weatherTempC: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}weather_temp_c'],
      ),
      weatherLocationUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}weather_location_updated_at'],
      ),
      devUseDirectOpenWeather: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dev_use_direct_open_weather'],
      )!,
      devOpenWeatherApiKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dev_open_weather_api_key'],
      ),
      weatherForecastJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}weather_forecast_json'],
      ),
      weatherChartTempColor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weather_chart_temp_color'],
      ),
      weatherChartRainColor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weather_chart_rain_color'],
      ),
      colorPaletteJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color_palette_json'],
      ),
    );
  }

  @override
  $SettingsTableTable createAlias(String alias) {
    return $SettingsTableTable(attachedDatabase, alias);
  }
}

class SettingsTableData extends DataClass
    implements Insertable<SettingsTableData> {
  final int id;
  final int accentColor;
  final bool weekStartsOnMonday;
  final bool showQuotes;
  final String journalHotkey;
  final String todoHotkey;
  final int rankingColorStart;
  final int rankingColorEnd;
  final bool timelineModeYearZero;
  final int? birthYear;
  final bool alertOnPeriodicPrompts;
  final int alertTimeHour;
  final bool hideCompletedTasks;
  final String? deviceId;
  final String? weatherLocationLabel;
  final double? weatherLat;
  final double? weatherLon;
  final String? weatherIcon;
  final DateTime? weatherFetchedAt;
  final int? weatherConditionCode;
  final double? weatherTempC;
  final DateTime? weatherLocationUpdatedAt;
  final bool devUseDirectOpenWeather;
  final String? devOpenWeatherApiKey;
  final String? weatherForecastJson;
  final int? weatherChartTempColor;
  final int? weatherChartRainColor;
  final String? colorPaletteJson;
  const SettingsTableData({
    required this.id,
    required this.accentColor,
    required this.weekStartsOnMonday,
    required this.showQuotes,
    required this.journalHotkey,
    required this.todoHotkey,
    required this.rankingColorStart,
    required this.rankingColorEnd,
    required this.timelineModeYearZero,
    this.birthYear,
    required this.alertOnPeriodicPrompts,
    required this.alertTimeHour,
    required this.hideCompletedTasks,
    this.deviceId,
    this.weatherLocationLabel,
    this.weatherLat,
    this.weatherLon,
    this.weatherIcon,
    this.weatherFetchedAt,
    this.weatherConditionCode,
    this.weatherTempC,
    this.weatherLocationUpdatedAt,
    required this.devUseDirectOpenWeather,
    this.devOpenWeatherApiKey,
    this.weatherForecastJson,
    this.weatherChartTempColor,
    this.weatherChartRainColor,
    this.colorPaletteJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['accent_color'] = Variable<int>(accentColor);
    map['week_starts_on_monday'] = Variable<bool>(weekStartsOnMonday);
    map['show_quotes'] = Variable<bool>(showQuotes);
    map['journal_hotkey'] = Variable<String>(journalHotkey);
    map['todo_hotkey'] = Variable<String>(todoHotkey);
    map['ranking_color_start'] = Variable<int>(rankingColorStart);
    map['ranking_color_end'] = Variable<int>(rankingColorEnd);
    map['timeline_mode_year_zero'] = Variable<bool>(timelineModeYearZero);
    if (!nullToAbsent || birthYear != null) {
      map['birth_year'] = Variable<int>(birthYear);
    }
    map['alert_on_periodic_prompts'] = Variable<bool>(alertOnPeriodicPrompts);
    map['alert_time_hour'] = Variable<int>(alertTimeHour);
    map['hide_completed_tasks'] = Variable<bool>(hideCompletedTasks);
    if (!nullToAbsent || deviceId != null) {
      map['device_id'] = Variable<String>(deviceId);
    }
    if (!nullToAbsent || weatherLocationLabel != null) {
      map['weather_location_label'] = Variable<String>(weatherLocationLabel);
    }
    if (!nullToAbsent || weatherLat != null) {
      map['weather_lat'] = Variable<double>(weatherLat);
    }
    if (!nullToAbsent || weatherLon != null) {
      map['weather_lon'] = Variable<double>(weatherLon);
    }
    if (!nullToAbsent || weatherIcon != null) {
      map['weather_icon'] = Variable<String>(weatherIcon);
    }
    if (!nullToAbsent || weatherFetchedAt != null) {
      map['weather_fetched_at'] = Variable<DateTime>(weatherFetchedAt);
    }
    if (!nullToAbsent || weatherConditionCode != null) {
      map['weather_condition_code'] = Variable<int>(weatherConditionCode);
    }
    if (!nullToAbsent || weatherTempC != null) {
      map['weather_temp_c'] = Variable<double>(weatherTempC);
    }
    if (!nullToAbsent || weatherLocationUpdatedAt != null) {
      map['weather_location_updated_at'] = Variable<DateTime>(
        weatherLocationUpdatedAt,
      );
    }
    map['dev_use_direct_open_weather'] = Variable<bool>(
      devUseDirectOpenWeather,
    );
    if (!nullToAbsent || devOpenWeatherApiKey != null) {
      map['dev_open_weather_api_key'] = Variable<String>(devOpenWeatherApiKey);
    }
    if (!nullToAbsent || weatherForecastJson != null) {
      map['weather_forecast_json'] = Variable<String>(weatherForecastJson);
    }
    if (!nullToAbsent || weatherChartTempColor != null) {
      map['weather_chart_temp_color'] = Variable<int>(weatherChartTempColor);
    }
    if (!nullToAbsent || weatherChartRainColor != null) {
      map['weather_chart_rain_color'] = Variable<int>(weatherChartRainColor);
    }
    if (!nullToAbsent || colorPaletteJson != null) {
      map['color_palette_json'] = Variable<String>(colorPaletteJson);
    }
    return map;
  }

  SettingsTableCompanion toCompanion(bool nullToAbsent) {
    return SettingsTableCompanion(
      id: Value(id),
      accentColor: Value(accentColor),
      weekStartsOnMonday: Value(weekStartsOnMonday),
      showQuotes: Value(showQuotes),
      journalHotkey: Value(journalHotkey),
      todoHotkey: Value(todoHotkey),
      rankingColorStart: Value(rankingColorStart),
      rankingColorEnd: Value(rankingColorEnd),
      timelineModeYearZero: Value(timelineModeYearZero),
      birthYear: birthYear == null && nullToAbsent
          ? const Value.absent()
          : Value(birthYear),
      alertOnPeriodicPrompts: Value(alertOnPeriodicPrompts),
      alertTimeHour: Value(alertTimeHour),
      hideCompletedTasks: Value(hideCompletedTasks),
      deviceId: deviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(deviceId),
      weatherLocationLabel: weatherLocationLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherLocationLabel),
      weatherLat: weatherLat == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherLat),
      weatherLon: weatherLon == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherLon),
      weatherIcon: weatherIcon == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherIcon),
      weatherFetchedAt: weatherFetchedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherFetchedAt),
      weatherConditionCode: weatherConditionCode == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherConditionCode),
      weatherTempC: weatherTempC == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherTempC),
      weatherLocationUpdatedAt: weatherLocationUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherLocationUpdatedAt),
      devUseDirectOpenWeather: Value(devUseDirectOpenWeather),
      devOpenWeatherApiKey: devOpenWeatherApiKey == null && nullToAbsent
          ? const Value.absent()
          : Value(devOpenWeatherApiKey),
      weatherForecastJson: weatherForecastJson == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherForecastJson),
      weatherChartTempColor: weatherChartTempColor == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherChartTempColor),
      weatherChartRainColor: weatherChartRainColor == null && nullToAbsent
          ? const Value.absent()
          : Value(weatherChartRainColor),
      colorPaletteJson: colorPaletteJson == null && nullToAbsent
          ? const Value.absent()
          : Value(colorPaletteJson),
    );
  }

  factory SettingsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingsTableData(
      id: serializer.fromJson<int>(json['id']),
      accentColor: serializer.fromJson<int>(json['accentColor']),
      weekStartsOnMonday: serializer.fromJson<bool>(json['weekStartsOnMonday']),
      showQuotes: serializer.fromJson<bool>(json['showQuotes']),
      journalHotkey: serializer.fromJson<String>(json['journalHotkey']),
      todoHotkey: serializer.fromJson<String>(json['todoHotkey']),
      rankingColorStart: serializer.fromJson<int>(json['rankingColorStart']),
      rankingColorEnd: serializer.fromJson<int>(json['rankingColorEnd']),
      timelineModeYearZero: serializer.fromJson<bool>(
        json['timelineModeYearZero'],
      ),
      birthYear: serializer.fromJson<int?>(json['birthYear']),
      alertOnPeriodicPrompts: serializer.fromJson<bool>(
        json['alertOnPeriodicPrompts'],
      ),
      alertTimeHour: serializer.fromJson<int>(json['alertTimeHour']),
      hideCompletedTasks: serializer.fromJson<bool>(json['hideCompletedTasks']),
      deviceId: serializer.fromJson<String?>(json['deviceId']),
      weatherLocationLabel: serializer.fromJson<String?>(
        json['weatherLocationLabel'],
      ),
      weatherLat: serializer.fromJson<double?>(json['weatherLat']),
      weatherLon: serializer.fromJson<double?>(json['weatherLon']),
      weatherIcon: serializer.fromJson<String?>(json['weatherIcon']),
      weatherFetchedAt: serializer.fromJson<DateTime?>(
        json['weatherFetchedAt'],
      ),
      weatherConditionCode: serializer.fromJson<int?>(
        json['weatherConditionCode'],
      ),
      weatherTempC: serializer.fromJson<double?>(json['weatherTempC']),
      weatherLocationUpdatedAt: serializer.fromJson<DateTime?>(
        json['weatherLocationUpdatedAt'],
      ),
      devUseDirectOpenWeather: serializer.fromJson<bool>(
        json['devUseDirectOpenWeather'],
      ),
      devOpenWeatherApiKey: serializer.fromJson<String?>(
        json['devOpenWeatherApiKey'],
      ),
      weatherForecastJson: serializer.fromJson<String?>(
        json['weatherForecastJson'],
      ),
      weatherChartTempColor: serializer.fromJson<int?>(
        json['weatherChartTempColor'],
      ),
      weatherChartRainColor: serializer.fromJson<int?>(
        json['weatherChartRainColor'],
      ),
      colorPaletteJson: serializer.fromJson<String?>(json['colorPaletteJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accentColor': serializer.toJson<int>(accentColor),
      'weekStartsOnMonday': serializer.toJson<bool>(weekStartsOnMonday),
      'showQuotes': serializer.toJson<bool>(showQuotes),
      'journalHotkey': serializer.toJson<String>(journalHotkey),
      'todoHotkey': serializer.toJson<String>(todoHotkey),
      'rankingColorStart': serializer.toJson<int>(rankingColorStart),
      'rankingColorEnd': serializer.toJson<int>(rankingColorEnd),
      'timelineModeYearZero': serializer.toJson<bool>(timelineModeYearZero),
      'birthYear': serializer.toJson<int?>(birthYear),
      'alertOnPeriodicPrompts': serializer.toJson<bool>(alertOnPeriodicPrompts),
      'alertTimeHour': serializer.toJson<int>(alertTimeHour),
      'hideCompletedTasks': serializer.toJson<bool>(hideCompletedTasks),
      'deviceId': serializer.toJson<String?>(deviceId),
      'weatherLocationLabel': serializer.toJson<String?>(weatherLocationLabel),
      'weatherLat': serializer.toJson<double?>(weatherLat),
      'weatherLon': serializer.toJson<double?>(weatherLon),
      'weatherIcon': serializer.toJson<String?>(weatherIcon),
      'weatherFetchedAt': serializer.toJson<DateTime?>(weatherFetchedAt),
      'weatherConditionCode': serializer.toJson<int?>(weatherConditionCode),
      'weatherTempC': serializer.toJson<double?>(weatherTempC),
      'weatherLocationUpdatedAt': serializer.toJson<DateTime?>(
        weatherLocationUpdatedAt,
      ),
      'devUseDirectOpenWeather': serializer.toJson<bool>(
        devUseDirectOpenWeather,
      ),
      'devOpenWeatherApiKey': serializer.toJson<String?>(devOpenWeatherApiKey),
      'weatherForecastJson': serializer.toJson<String?>(weatherForecastJson),
      'weatherChartTempColor': serializer.toJson<int?>(weatherChartTempColor),
      'weatherChartRainColor': serializer.toJson<int?>(weatherChartRainColor),
      'colorPaletteJson': serializer.toJson<String?>(colorPaletteJson),
    };
  }

  SettingsTableData copyWith({
    int? id,
    int? accentColor,
    bool? weekStartsOnMonday,
    bool? showQuotes,
    String? journalHotkey,
    String? todoHotkey,
    int? rankingColorStart,
    int? rankingColorEnd,
    bool? timelineModeYearZero,
    Value<int?> birthYear = const Value.absent(),
    bool? alertOnPeriodicPrompts,
    int? alertTimeHour,
    bool? hideCompletedTasks,
    Value<String?> deviceId = const Value.absent(),
    Value<String?> weatherLocationLabel = const Value.absent(),
    Value<double?> weatherLat = const Value.absent(),
    Value<double?> weatherLon = const Value.absent(),
    Value<String?> weatherIcon = const Value.absent(),
    Value<DateTime?> weatherFetchedAt = const Value.absent(),
    Value<int?> weatherConditionCode = const Value.absent(),
    Value<double?> weatherTempC = const Value.absent(),
    Value<DateTime?> weatherLocationUpdatedAt = const Value.absent(),
    bool? devUseDirectOpenWeather,
    Value<String?> devOpenWeatherApiKey = const Value.absent(),
    Value<String?> weatherForecastJson = const Value.absent(),
    Value<int?> weatherChartTempColor = const Value.absent(),
    Value<int?> weatherChartRainColor = const Value.absent(),
    Value<String?> colorPaletteJson = const Value.absent(),
  }) => SettingsTableData(
    id: id ?? this.id,
    accentColor: accentColor ?? this.accentColor,
    weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
    showQuotes: showQuotes ?? this.showQuotes,
    journalHotkey: journalHotkey ?? this.journalHotkey,
    todoHotkey: todoHotkey ?? this.todoHotkey,
    rankingColorStart: rankingColorStart ?? this.rankingColorStart,
    rankingColorEnd: rankingColorEnd ?? this.rankingColorEnd,
    timelineModeYearZero: timelineModeYearZero ?? this.timelineModeYearZero,
    birthYear: birthYear.present ? birthYear.value : this.birthYear,
    alertOnPeriodicPrompts:
        alertOnPeriodicPrompts ?? this.alertOnPeriodicPrompts,
    alertTimeHour: alertTimeHour ?? this.alertTimeHour,
    hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
    deviceId: deviceId.present ? deviceId.value : this.deviceId,
    weatherLocationLabel: weatherLocationLabel.present
        ? weatherLocationLabel.value
        : this.weatherLocationLabel,
    weatherLat: weatherLat.present ? weatherLat.value : this.weatherLat,
    weatherLon: weatherLon.present ? weatherLon.value : this.weatherLon,
    weatherIcon: weatherIcon.present ? weatherIcon.value : this.weatherIcon,
    weatherFetchedAt: weatherFetchedAt.present
        ? weatherFetchedAt.value
        : this.weatherFetchedAt,
    weatherConditionCode: weatherConditionCode.present
        ? weatherConditionCode.value
        : this.weatherConditionCode,
    weatherTempC: weatherTempC.present ? weatherTempC.value : this.weatherTempC,
    weatherLocationUpdatedAt: weatherLocationUpdatedAt.present
        ? weatherLocationUpdatedAt.value
        : this.weatherLocationUpdatedAt,
    devUseDirectOpenWeather:
        devUseDirectOpenWeather ?? this.devUseDirectOpenWeather,
    devOpenWeatherApiKey: devOpenWeatherApiKey.present
        ? devOpenWeatherApiKey.value
        : this.devOpenWeatherApiKey,
    weatherForecastJson: weatherForecastJson.present
        ? weatherForecastJson.value
        : this.weatherForecastJson,
    weatherChartTempColor: weatherChartTempColor.present
        ? weatherChartTempColor.value
        : this.weatherChartTempColor,
    weatherChartRainColor: weatherChartRainColor.present
        ? weatherChartRainColor.value
        : this.weatherChartRainColor,
    colorPaletteJson: colorPaletteJson.present
        ? colorPaletteJson.value
        : this.colorPaletteJson,
  );
  SettingsTableData copyWithCompanion(SettingsTableCompanion data) {
    return SettingsTableData(
      id: data.id.present ? data.id.value : this.id,
      accentColor: data.accentColor.present
          ? data.accentColor.value
          : this.accentColor,
      weekStartsOnMonday: data.weekStartsOnMonday.present
          ? data.weekStartsOnMonday.value
          : this.weekStartsOnMonday,
      showQuotes: data.showQuotes.present
          ? data.showQuotes.value
          : this.showQuotes,
      journalHotkey: data.journalHotkey.present
          ? data.journalHotkey.value
          : this.journalHotkey,
      todoHotkey: data.todoHotkey.present
          ? data.todoHotkey.value
          : this.todoHotkey,
      rankingColorStart: data.rankingColorStart.present
          ? data.rankingColorStart.value
          : this.rankingColorStart,
      rankingColorEnd: data.rankingColorEnd.present
          ? data.rankingColorEnd.value
          : this.rankingColorEnd,
      timelineModeYearZero: data.timelineModeYearZero.present
          ? data.timelineModeYearZero.value
          : this.timelineModeYearZero,
      birthYear: data.birthYear.present ? data.birthYear.value : this.birthYear,
      alertOnPeriodicPrompts: data.alertOnPeriodicPrompts.present
          ? data.alertOnPeriodicPrompts.value
          : this.alertOnPeriodicPrompts,
      alertTimeHour: data.alertTimeHour.present
          ? data.alertTimeHour.value
          : this.alertTimeHour,
      hideCompletedTasks: data.hideCompletedTasks.present
          ? data.hideCompletedTasks.value
          : this.hideCompletedTasks,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      weatherLocationLabel: data.weatherLocationLabel.present
          ? data.weatherLocationLabel.value
          : this.weatherLocationLabel,
      weatherLat: data.weatherLat.present
          ? data.weatherLat.value
          : this.weatherLat,
      weatherLon: data.weatherLon.present
          ? data.weatherLon.value
          : this.weatherLon,
      weatherIcon: data.weatherIcon.present
          ? data.weatherIcon.value
          : this.weatherIcon,
      weatherFetchedAt: data.weatherFetchedAt.present
          ? data.weatherFetchedAt.value
          : this.weatherFetchedAt,
      weatherConditionCode: data.weatherConditionCode.present
          ? data.weatherConditionCode.value
          : this.weatherConditionCode,
      weatherTempC: data.weatherTempC.present
          ? data.weatherTempC.value
          : this.weatherTempC,
      weatherLocationUpdatedAt: data.weatherLocationUpdatedAt.present
          ? data.weatherLocationUpdatedAt.value
          : this.weatherLocationUpdatedAt,
      devUseDirectOpenWeather: data.devUseDirectOpenWeather.present
          ? data.devUseDirectOpenWeather.value
          : this.devUseDirectOpenWeather,
      devOpenWeatherApiKey: data.devOpenWeatherApiKey.present
          ? data.devOpenWeatherApiKey.value
          : this.devOpenWeatherApiKey,
      weatherForecastJson: data.weatherForecastJson.present
          ? data.weatherForecastJson.value
          : this.weatherForecastJson,
      weatherChartTempColor: data.weatherChartTempColor.present
          ? data.weatherChartTempColor.value
          : this.weatherChartTempColor,
      weatherChartRainColor: data.weatherChartRainColor.present
          ? data.weatherChartRainColor.value
          : this.weatherChartRainColor,
      colorPaletteJson: data.colorPaletteJson.present
          ? data.colorPaletteJson.value
          : this.colorPaletteJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingsTableData(')
          ..write('id: $id, ')
          ..write('accentColor: $accentColor, ')
          ..write('weekStartsOnMonday: $weekStartsOnMonday, ')
          ..write('showQuotes: $showQuotes, ')
          ..write('journalHotkey: $journalHotkey, ')
          ..write('todoHotkey: $todoHotkey, ')
          ..write('rankingColorStart: $rankingColorStart, ')
          ..write('rankingColorEnd: $rankingColorEnd, ')
          ..write('timelineModeYearZero: $timelineModeYearZero, ')
          ..write('birthYear: $birthYear, ')
          ..write('alertOnPeriodicPrompts: $alertOnPeriodicPrompts, ')
          ..write('alertTimeHour: $alertTimeHour, ')
          ..write('hideCompletedTasks: $hideCompletedTasks, ')
          ..write('deviceId: $deviceId, ')
          ..write('weatherLocationLabel: $weatherLocationLabel, ')
          ..write('weatherLat: $weatherLat, ')
          ..write('weatherLon: $weatherLon, ')
          ..write('weatherIcon: $weatherIcon, ')
          ..write('weatherFetchedAt: $weatherFetchedAt, ')
          ..write('weatherConditionCode: $weatherConditionCode, ')
          ..write('weatherTempC: $weatherTempC, ')
          ..write('weatherLocationUpdatedAt: $weatherLocationUpdatedAt, ')
          ..write('devUseDirectOpenWeather: $devUseDirectOpenWeather, ')
          ..write('devOpenWeatherApiKey: $devOpenWeatherApiKey, ')
          ..write('weatherForecastJson: $weatherForecastJson, ')
          ..write('weatherChartTempColor: $weatherChartTempColor, ')
          ..write('weatherChartRainColor: $weatherChartRainColor, ')
          ..write('colorPaletteJson: $colorPaletteJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accentColor,
    weekStartsOnMonday,
    showQuotes,
    journalHotkey,
    todoHotkey,
    rankingColorStart,
    rankingColorEnd,
    timelineModeYearZero,
    birthYear,
    alertOnPeriodicPrompts,
    alertTimeHour,
    hideCompletedTasks,
    deviceId,
    weatherLocationLabel,
    weatherLat,
    weatherLon,
    weatherIcon,
    weatherFetchedAt,
    weatherConditionCode,
    weatherTempC,
    weatherLocationUpdatedAt,
    devUseDirectOpenWeather,
    devOpenWeatherApiKey,
    weatherForecastJson,
    weatherChartTempColor,
    weatherChartRainColor,
    colorPaletteJson,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingsTableData &&
          other.id == this.id &&
          other.accentColor == this.accentColor &&
          other.weekStartsOnMonday == this.weekStartsOnMonday &&
          other.showQuotes == this.showQuotes &&
          other.journalHotkey == this.journalHotkey &&
          other.todoHotkey == this.todoHotkey &&
          other.rankingColorStart == this.rankingColorStart &&
          other.rankingColorEnd == this.rankingColorEnd &&
          other.timelineModeYearZero == this.timelineModeYearZero &&
          other.birthYear == this.birthYear &&
          other.alertOnPeriodicPrompts == this.alertOnPeriodicPrompts &&
          other.alertTimeHour == this.alertTimeHour &&
          other.hideCompletedTasks == this.hideCompletedTasks &&
          other.deviceId == this.deviceId &&
          other.weatherLocationLabel == this.weatherLocationLabel &&
          other.weatherLat == this.weatherLat &&
          other.weatherLon == this.weatherLon &&
          other.weatherIcon == this.weatherIcon &&
          other.weatherFetchedAt == this.weatherFetchedAt &&
          other.weatherConditionCode == this.weatherConditionCode &&
          other.weatherTempC == this.weatherTempC &&
          other.weatherLocationUpdatedAt == this.weatherLocationUpdatedAt &&
          other.devUseDirectOpenWeather == this.devUseDirectOpenWeather &&
          other.devOpenWeatherApiKey == this.devOpenWeatherApiKey &&
          other.weatherForecastJson == this.weatherForecastJson &&
          other.weatherChartTempColor == this.weatherChartTempColor &&
          other.weatherChartRainColor == this.weatherChartRainColor &&
          other.colorPaletteJson == this.colorPaletteJson);
}

class SettingsTableCompanion extends UpdateCompanion<SettingsTableData> {
  final Value<int> id;
  final Value<int> accentColor;
  final Value<bool> weekStartsOnMonday;
  final Value<bool> showQuotes;
  final Value<String> journalHotkey;
  final Value<String> todoHotkey;
  final Value<int> rankingColorStart;
  final Value<int> rankingColorEnd;
  final Value<bool> timelineModeYearZero;
  final Value<int?> birthYear;
  final Value<bool> alertOnPeriodicPrompts;
  final Value<int> alertTimeHour;
  final Value<bool> hideCompletedTasks;
  final Value<String?> deviceId;
  final Value<String?> weatherLocationLabel;
  final Value<double?> weatherLat;
  final Value<double?> weatherLon;
  final Value<String?> weatherIcon;
  final Value<DateTime?> weatherFetchedAt;
  final Value<int?> weatherConditionCode;
  final Value<double?> weatherTempC;
  final Value<DateTime?> weatherLocationUpdatedAt;
  final Value<bool> devUseDirectOpenWeather;
  final Value<String?> devOpenWeatherApiKey;
  final Value<String?> weatherForecastJson;
  final Value<int?> weatherChartTempColor;
  final Value<int?> weatherChartRainColor;
  final Value<String?> colorPaletteJson;
  const SettingsTableCompanion({
    this.id = const Value.absent(),
    this.accentColor = const Value.absent(),
    this.weekStartsOnMonday = const Value.absent(),
    this.showQuotes = const Value.absent(),
    this.journalHotkey = const Value.absent(),
    this.todoHotkey = const Value.absent(),
    this.rankingColorStart = const Value.absent(),
    this.rankingColorEnd = const Value.absent(),
    this.timelineModeYearZero = const Value.absent(),
    this.birthYear = const Value.absent(),
    this.alertOnPeriodicPrompts = const Value.absent(),
    this.alertTimeHour = const Value.absent(),
    this.hideCompletedTasks = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.weatherLocationLabel = const Value.absent(),
    this.weatherLat = const Value.absent(),
    this.weatherLon = const Value.absent(),
    this.weatherIcon = const Value.absent(),
    this.weatherFetchedAt = const Value.absent(),
    this.weatherConditionCode = const Value.absent(),
    this.weatherTempC = const Value.absent(),
    this.weatherLocationUpdatedAt = const Value.absent(),
    this.devUseDirectOpenWeather = const Value.absent(),
    this.devOpenWeatherApiKey = const Value.absent(),
    this.weatherForecastJson = const Value.absent(),
    this.weatherChartTempColor = const Value.absent(),
    this.weatherChartRainColor = const Value.absent(),
    this.colorPaletteJson = const Value.absent(),
  });
  SettingsTableCompanion.insert({
    this.id = const Value.absent(),
    this.accentColor = const Value.absent(),
    this.weekStartsOnMonday = const Value.absent(),
    this.showQuotes = const Value.absent(),
    this.journalHotkey = const Value.absent(),
    this.todoHotkey = const Value.absent(),
    this.rankingColorStart = const Value.absent(),
    this.rankingColorEnd = const Value.absent(),
    this.timelineModeYearZero = const Value.absent(),
    this.birthYear = const Value.absent(),
    this.alertOnPeriodicPrompts = const Value.absent(),
    this.alertTimeHour = const Value.absent(),
    this.hideCompletedTasks = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.weatherLocationLabel = const Value.absent(),
    this.weatherLat = const Value.absent(),
    this.weatherLon = const Value.absent(),
    this.weatherIcon = const Value.absent(),
    this.weatherFetchedAt = const Value.absent(),
    this.weatherConditionCode = const Value.absent(),
    this.weatherTempC = const Value.absent(),
    this.weatherLocationUpdatedAt = const Value.absent(),
    this.devUseDirectOpenWeather = const Value.absent(),
    this.devOpenWeatherApiKey = const Value.absent(),
    this.weatherForecastJson = const Value.absent(),
    this.weatherChartTempColor = const Value.absent(),
    this.weatherChartRainColor = const Value.absent(),
    this.colorPaletteJson = const Value.absent(),
  });
  static Insertable<SettingsTableData> custom({
    Expression<int>? id,
    Expression<int>? accentColor,
    Expression<bool>? weekStartsOnMonday,
    Expression<bool>? showQuotes,
    Expression<String>? journalHotkey,
    Expression<String>? todoHotkey,
    Expression<int>? rankingColorStart,
    Expression<int>? rankingColorEnd,
    Expression<bool>? timelineModeYearZero,
    Expression<int>? birthYear,
    Expression<bool>? alertOnPeriodicPrompts,
    Expression<int>? alertTimeHour,
    Expression<bool>? hideCompletedTasks,
    Expression<String>? deviceId,
    Expression<String>? weatherLocationLabel,
    Expression<double>? weatherLat,
    Expression<double>? weatherLon,
    Expression<String>? weatherIcon,
    Expression<DateTime>? weatherFetchedAt,
    Expression<int>? weatherConditionCode,
    Expression<double>? weatherTempC,
    Expression<DateTime>? weatherLocationUpdatedAt,
    Expression<bool>? devUseDirectOpenWeather,
    Expression<String>? devOpenWeatherApiKey,
    Expression<String>? weatherForecastJson,
    Expression<int>? weatherChartTempColor,
    Expression<int>? weatherChartRainColor,
    Expression<String>? colorPaletteJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accentColor != null) 'accent_color': accentColor,
      if (weekStartsOnMonday != null)
        'week_starts_on_monday': weekStartsOnMonday,
      if (showQuotes != null) 'show_quotes': showQuotes,
      if (journalHotkey != null) 'journal_hotkey': journalHotkey,
      if (todoHotkey != null) 'todo_hotkey': todoHotkey,
      if (rankingColorStart != null) 'ranking_color_start': rankingColorStart,
      if (rankingColorEnd != null) 'ranking_color_end': rankingColorEnd,
      if (timelineModeYearZero != null)
        'timeline_mode_year_zero': timelineModeYearZero,
      if (birthYear != null) 'birth_year': birthYear,
      if (alertOnPeriodicPrompts != null)
        'alert_on_periodic_prompts': alertOnPeriodicPrompts,
      if (alertTimeHour != null) 'alert_time_hour': alertTimeHour,
      if (hideCompletedTasks != null)
        'hide_completed_tasks': hideCompletedTasks,
      if (deviceId != null) 'device_id': deviceId,
      if (weatherLocationLabel != null)
        'weather_location_label': weatherLocationLabel,
      if (weatherLat != null) 'weather_lat': weatherLat,
      if (weatherLon != null) 'weather_lon': weatherLon,
      if (weatherIcon != null) 'weather_icon': weatherIcon,
      if (weatherFetchedAt != null) 'weather_fetched_at': weatherFetchedAt,
      if (weatherConditionCode != null)
        'weather_condition_code': weatherConditionCode,
      if (weatherTempC != null) 'weather_temp_c': weatherTempC,
      if (weatherLocationUpdatedAt != null)
        'weather_location_updated_at': weatherLocationUpdatedAt,
      if (devUseDirectOpenWeather != null)
        'dev_use_direct_open_weather': devUseDirectOpenWeather,
      if (devOpenWeatherApiKey != null)
        'dev_open_weather_api_key': devOpenWeatherApiKey,
      if (weatherForecastJson != null)
        'weather_forecast_json': weatherForecastJson,
      if (weatherChartTempColor != null)
        'weather_chart_temp_color': weatherChartTempColor,
      if (weatherChartRainColor != null)
        'weather_chart_rain_color': weatherChartRainColor,
      if (colorPaletteJson != null) 'color_palette_json': colorPaletteJson,
    });
  }

  SettingsTableCompanion copyWith({
    Value<int>? id,
    Value<int>? accentColor,
    Value<bool>? weekStartsOnMonday,
    Value<bool>? showQuotes,
    Value<String>? journalHotkey,
    Value<String>? todoHotkey,
    Value<int>? rankingColorStart,
    Value<int>? rankingColorEnd,
    Value<bool>? timelineModeYearZero,
    Value<int?>? birthYear,
    Value<bool>? alertOnPeriodicPrompts,
    Value<int>? alertTimeHour,
    Value<bool>? hideCompletedTasks,
    Value<String?>? deviceId,
    Value<String?>? weatherLocationLabel,
    Value<double?>? weatherLat,
    Value<double?>? weatherLon,
    Value<String?>? weatherIcon,
    Value<DateTime?>? weatherFetchedAt,
    Value<int?>? weatherConditionCode,
    Value<double?>? weatherTempC,
    Value<DateTime?>? weatherLocationUpdatedAt,
    Value<bool>? devUseDirectOpenWeather,
    Value<String?>? devOpenWeatherApiKey,
    Value<String?>? weatherForecastJson,
    Value<int?>? weatherChartTempColor,
    Value<int?>? weatherChartRainColor,
    Value<String?>? colorPaletteJson,
  }) {
    return SettingsTableCompanion(
      id: id ?? this.id,
      accentColor: accentColor ?? this.accentColor,
      weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
      showQuotes: showQuotes ?? this.showQuotes,
      journalHotkey: journalHotkey ?? this.journalHotkey,
      todoHotkey: todoHotkey ?? this.todoHotkey,
      rankingColorStart: rankingColorStart ?? this.rankingColorStart,
      rankingColorEnd: rankingColorEnd ?? this.rankingColorEnd,
      timelineModeYearZero: timelineModeYearZero ?? this.timelineModeYearZero,
      birthYear: birthYear ?? this.birthYear,
      alertOnPeriodicPrompts:
          alertOnPeriodicPrompts ?? this.alertOnPeriodicPrompts,
      alertTimeHour: alertTimeHour ?? this.alertTimeHour,
      hideCompletedTasks: hideCompletedTasks ?? this.hideCompletedTasks,
      deviceId: deviceId ?? this.deviceId,
      weatherLocationLabel: weatherLocationLabel ?? this.weatherLocationLabel,
      weatherLat: weatherLat ?? this.weatherLat,
      weatherLon: weatherLon ?? this.weatherLon,
      weatherIcon: weatherIcon ?? this.weatherIcon,
      weatherFetchedAt: weatherFetchedAt ?? this.weatherFetchedAt,
      weatherConditionCode: weatherConditionCode ?? this.weatherConditionCode,
      weatherTempC: weatherTempC ?? this.weatherTempC,
      weatherLocationUpdatedAt:
          weatherLocationUpdatedAt ?? this.weatherLocationUpdatedAt,
      devUseDirectOpenWeather:
          devUseDirectOpenWeather ?? this.devUseDirectOpenWeather,
      devOpenWeatherApiKey: devOpenWeatherApiKey ?? this.devOpenWeatherApiKey,
      weatherForecastJson: weatherForecastJson ?? this.weatherForecastJson,
      weatherChartTempColor:
          weatherChartTempColor ?? this.weatherChartTempColor,
      weatherChartRainColor:
          weatherChartRainColor ?? this.weatherChartRainColor,
      colorPaletteJson: colorPaletteJson ?? this.colorPaletteJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accentColor.present) {
      map['accent_color'] = Variable<int>(accentColor.value);
    }
    if (weekStartsOnMonday.present) {
      map['week_starts_on_monday'] = Variable<bool>(weekStartsOnMonday.value);
    }
    if (showQuotes.present) {
      map['show_quotes'] = Variable<bool>(showQuotes.value);
    }
    if (journalHotkey.present) {
      map['journal_hotkey'] = Variable<String>(journalHotkey.value);
    }
    if (todoHotkey.present) {
      map['todo_hotkey'] = Variable<String>(todoHotkey.value);
    }
    if (rankingColorStart.present) {
      map['ranking_color_start'] = Variable<int>(rankingColorStart.value);
    }
    if (rankingColorEnd.present) {
      map['ranking_color_end'] = Variable<int>(rankingColorEnd.value);
    }
    if (timelineModeYearZero.present) {
      map['timeline_mode_year_zero'] = Variable<bool>(
        timelineModeYearZero.value,
      );
    }
    if (birthYear.present) {
      map['birth_year'] = Variable<int>(birthYear.value);
    }
    if (alertOnPeriodicPrompts.present) {
      map['alert_on_periodic_prompts'] = Variable<bool>(
        alertOnPeriodicPrompts.value,
      );
    }
    if (alertTimeHour.present) {
      map['alert_time_hour'] = Variable<int>(alertTimeHour.value);
    }
    if (hideCompletedTasks.present) {
      map['hide_completed_tasks'] = Variable<bool>(hideCompletedTasks.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (weatherLocationLabel.present) {
      map['weather_location_label'] = Variable<String>(
        weatherLocationLabel.value,
      );
    }
    if (weatherLat.present) {
      map['weather_lat'] = Variable<double>(weatherLat.value);
    }
    if (weatherLon.present) {
      map['weather_lon'] = Variable<double>(weatherLon.value);
    }
    if (weatherIcon.present) {
      map['weather_icon'] = Variable<String>(weatherIcon.value);
    }
    if (weatherFetchedAt.present) {
      map['weather_fetched_at'] = Variable<DateTime>(weatherFetchedAt.value);
    }
    if (weatherConditionCode.present) {
      map['weather_condition_code'] = Variable<int>(weatherConditionCode.value);
    }
    if (weatherTempC.present) {
      map['weather_temp_c'] = Variable<double>(weatherTempC.value);
    }
    if (weatherLocationUpdatedAt.present) {
      map['weather_location_updated_at'] = Variable<DateTime>(
        weatherLocationUpdatedAt.value,
      );
    }
    if (devUseDirectOpenWeather.present) {
      map['dev_use_direct_open_weather'] = Variable<bool>(
        devUseDirectOpenWeather.value,
      );
    }
    if (devOpenWeatherApiKey.present) {
      map['dev_open_weather_api_key'] = Variable<String>(
        devOpenWeatherApiKey.value,
      );
    }
    if (weatherForecastJson.present) {
      map['weather_forecast_json'] = Variable<String>(
        weatherForecastJson.value,
      );
    }
    if (weatherChartTempColor.present) {
      map['weather_chart_temp_color'] = Variable<int>(
        weatherChartTempColor.value,
      );
    }
    if (weatherChartRainColor.present) {
      map['weather_chart_rain_color'] = Variable<int>(
        weatherChartRainColor.value,
      );
    }
    if (colorPaletteJson.present) {
      map['color_palette_json'] = Variable<String>(colorPaletteJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsTableCompanion(')
          ..write('id: $id, ')
          ..write('accentColor: $accentColor, ')
          ..write('weekStartsOnMonday: $weekStartsOnMonday, ')
          ..write('showQuotes: $showQuotes, ')
          ..write('journalHotkey: $journalHotkey, ')
          ..write('todoHotkey: $todoHotkey, ')
          ..write('rankingColorStart: $rankingColorStart, ')
          ..write('rankingColorEnd: $rankingColorEnd, ')
          ..write('timelineModeYearZero: $timelineModeYearZero, ')
          ..write('birthYear: $birthYear, ')
          ..write('alertOnPeriodicPrompts: $alertOnPeriodicPrompts, ')
          ..write('alertTimeHour: $alertTimeHour, ')
          ..write('hideCompletedTasks: $hideCompletedTasks, ')
          ..write('deviceId: $deviceId, ')
          ..write('weatherLocationLabel: $weatherLocationLabel, ')
          ..write('weatherLat: $weatherLat, ')
          ..write('weatherLon: $weatherLon, ')
          ..write('weatherIcon: $weatherIcon, ')
          ..write('weatherFetchedAt: $weatherFetchedAt, ')
          ..write('weatherConditionCode: $weatherConditionCode, ')
          ..write('weatherTempC: $weatherTempC, ')
          ..write('weatherLocationUpdatedAt: $weatherLocationUpdatedAt, ')
          ..write('devUseDirectOpenWeather: $devUseDirectOpenWeather, ')
          ..write('devOpenWeatherApiKey: $devOpenWeatherApiKey, ')
          ..write('weatherForecastJson: $weatherForecastJson, ')
          ..write('weatherChartTempColor: $weatherChartTempColor, ')
          ..write('weatherChartRainColor: $weatherChartRainColor, ')
          ..write('colorPaletteJson: $colorPaletteJson')
          ..write(')'))
        .toString();
  }
}

class $TagColorsTableTable extends TagColorsTable
    with TableInfo<$TagColorsTableTable, TagColorsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagColorsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tagMeta = const VerificationMeta('tag');
  @override
  late final GeneratedColumn<String> tag = GeneratedColumn<String>(
    'tag',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [tag, colorValue];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tag_colors_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TagColorsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tag')) {
      context.handle(
        _tagMeta,
        tag.isAcceptableOrUnknown(data['tag']!, _tagMeta),
      );
    } else if (isInserting) {
      context.missing(_tagMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    } else if (isInserting) {
      context.missing(_colorValueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tag};
  @override
  TagColorsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TagColorsTableData(
      tag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tag'],
      )!,
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      )!,
    );
  }

  @override
  $TagColorsTableTable createAlias(String alias) {
    return $TagColorsTableTable(attachedDatabase, alias);
  }
}

class TagColorsTableData extends DataClass
    implements Insertable<TagColorsTableData> {
  final String tag;
  final int colorValue;
  const TagColorsTableData({required this.tag, required this.colorValue});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tag'] = Variable<String>(tag);
    map['color_value'] = Variable<int>(colorValue);
    return map;
  }

  TagColorsTableCompanion toCompanion(bool nullToAbsent) {
    return TagColorsTableCompanion(
      tag: Value(tag),
      colorValue: Value(colorValue),
    );
  }

  factory TagColorsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TagColorsTableData(
      tag: serializer.fromJson<String>(json['tag']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tag': serializer.toJson<String>(tag),
      'colorValue': serializer.toJson<int>(colorValue),
    };
  }

  TagColorsTableData copyWith({String? tag, int? colorValue}) =>
      TagColorsTableData(
        tag: tag ?? this.tag,
        colorValue: colorValue ?? this.colorValue,
      );
  TagColorsTableData copyWithCompanion(TagColorsTableCompanion data) {
    return TagColorsTableData(
      tag: data.tag.present ? data.tag.value : this.tag,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TagColorsTableData(')
          ..write('tag: $tag, ')
          ..write('colorValue: $colorValue')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(tag, colorValue);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TagColorsTableData &&
          other.tag == this.tag &&
          other.colorValue == this.colorValue);
}

class TagColorsTableCompanion extends UpdateCompanion<TagColorsTableData> {
  final Value<String> tag;
  final Value<int> colorValue;
  final Value<int> rowid;
  const TagColorsTableCompanion({
    this.tag = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TagColorsTableCompanion.insert({
    required String tag,
    required int colorValue,
    this.rowid = const Value.absent(),
  }) : tag = Value(tag),
       colorValue = Value(colorValue);
  static Insertable<TagColorsTableData> custom({
    Expression<String>? tag,
    Expression<int>? colorValue,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tag != null) 'tag': tag,
      if (colorValue != null) 'color_value': colorValue,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TagColorsTableCompanion copyWith({
    Value<String>? tag,
    Value<int>? colorValue,
    Value<int>? rowid,
  }) {
    return TagColorsTableCompanion(
      tag: tag ?? this.tag,
      colorValue: colorValue ?? this.colorValue,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tag.present) {
      map['tag'] = Variable<String>(tag.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagColorsTableCompanion(')
          ..write('tag: $tag, ')
          ..write('colorValue: $colorValue, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $JournalsTableTable journalsTable = $JournalsTableTable(this);
  late final $JournalEntriesTableTable journalEntriesTable =
      $JournalEntriesTableTable(this);
  late final $TodoListsTableTable todoListsTable = $TodoListsTableTable(this);
  late final $TodoTasksTableTable todoTasksTable = $TodoTasksTableTable(this);
  late final $CalendarEventsTableTable calendarEventsTable =
      $CalendarEventsTableTable(this);
  late final $TrackersTableTable trackersTable = $TrackersTableTable(this);
  late final $TrackerValuesTableTable trackerValuesTable =
      $TrackerValuesTableTable(this);
  late final $RankingConfigsTableTable rankingConfigsTable =
      $RankingConfigsTableTable(this);
  late final $RankingValuesTableTable rankingValuesTable =
      $RankingValuesTableTable(this);
  late final $SettingsTableTable settingsTable = $SettingsTableTable(this);
  late final $TagColorsTableTable tagColorsTable = $TagColorsTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    journalsTable,
    journalEntriesTable,
    todoListsTable,
    todoTasksTable,
    calendarEventsTable,
    trackersTable,
    trackerValuesTable,
    rankingConfigsTable,
    rankingValuesTable,
    settingsTable,
    tagColorsTable,
  ];
}

typedef $$JournalsTableTableCreateCompanionBuilder =
    JournalsTableCompanion Function({
      required String id,
      required String name,
      Value<int?> colorValue,
      Value<bool> guidedJournaling,
      Value<int> promptCycleDays,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$JournalsTableTableUpdateCompanionBuilder =
    JournalsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int?> colorValue,
      Value<bool> guidedJournaling,
      Value<int> promptCycleDays,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$JournalsTableTableFilterComposer
    extends Composer<_$AppDatabase, $JournalsTableTable> {
  $$JournalsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get guidedJournaling => $composableBuilder(
    column: $table.guidedJournaling,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptCycleDays => $composableBuilder(
    column: $table.promptCycleDays,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JournalsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $JournalsTableTable> {
  $$JournalsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get guidedJournaling => $composableBuilder(
    column: $table.guidedJournaling,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptCycleDays => $composableBuilder(
    column: $table.promptCycleDays,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JournalsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $JournalsTableTable> {
  $$JournalsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get guidedJournaling => $composableBuilder(
    column: $table.guidedJournaling,
    builder: (column) => column,
  );

  GeneratedColumn<int> get promptCycleDays => $composableBuilder(
    column: $table.promptCycleDays,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$JournalsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $JournalsTableTable,
          JournalsTableData,
          $$JournalsTableTableFilterComposer,
          $$JournalsTableTableOrderingComposer,
          $$JournalsTableTableAnnotationComposer,
          $$JournalsTableTableCreateCompanionBuilder,
          $$JournalsTableTableUpdateCompanionBuilder,
          (
            JournalsTableData,
            BaseReferences<
              _$AppDatabase,
              $JournalsTableTable,
              JournalsTableData
            >,
          ),
          JournalsTableData,
          PrefetchHooks Function()
        > {
  $$JournalsTableTableTableManager(_$AppDatabase db, $JournalsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JournalsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JournalsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$JournalsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> colorValue = const Value.absent(),
                Value<bool> guidedJournaling = const Value.absent(),
                Value<int> promptCycleDays = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => JournalsTableCompanion(
                id: id,
                name: name,
                colorValue: colorValue,
                guidedJournaling: guidedJournaling,
                promptCycleDays: promptCycleDays,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int?> colorValue = const Value.absent(),
                Value<bool> guidedJournaling = const Value.absent(),
                Value<int> promptCycleDays = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => JournalsTableCompanion.insert(
                id: id,
                name: name,
                colorValue: colorValue,
                guidedJournaling: guidedJournaling,
                promptCycleDays: promptCycleDays,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$JournalsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $JournalsTableTable,
      JournalsTableData,
      $$JournalsTableTableFilterComposer,
      $$JournalsTableTableOrderingComposer,
      $$JournalsTableTableAnnotationComposer,
      $$JournalsTableTableCreateCompanionBuilder,
      $$JournalsTableTableUpdateCompanionBuilder,
      (
        JournalsTableData,
        BaseReferences<_$AppDatabase, $JournalsTableTable, JournalsTableData>,
      ),
      JournalsTableData,
      PrefetchHooks Function()
    >;
typedef $$JournalEntriesTableTableCreateCompanionBuilder =
    JournalEntriesTableCompanion Function({
      required String id,
      required String journalId,
      required String title,
      required String body,
      Value<String?> richBodyJson,
      required DateTime entryDate,
      Value<DateTime?> timestamp,
      Value<String> tagsJson,
      Value<int?> mood,
      Value<String?> quoteId,
      Value<String?> customQuote,
      Value<String?> weatherIcon,
      Value<String?> guidedPrompt,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$JournalEntriesTableTableUpdateCompanionBuilder =
    JournalEntriesTableCompanion Function({
      Value<String> id,
      Value<String> journalId,
      Value<String> title,
      Value<String> body,
      Value<String?> richBodyJson,
      Value<DateTime> entryDate,
      Value<DateTime?> timestamp,
      Value<String> tagsJson,
      Value<int?> mood,
      Value<String?> quoteId,
      Value<String?> customQuote,
      Value<String?> weatherIcon,
      Value<String?> guidedPrompt,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$JournalEntriesTableTableFilterComposer
    extends Composer<_$AppDatabase, $JournalEntriesTableTable> {
  $$JournalEntriesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get journalId => $composableBuilder(
    column: $table.journalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get richBodyJson => $composableBuilder(
    column: $table.richBodyJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get entryDate => $composableBuilder(
    column: $table.entryDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mood => $composableBuilder(
    column: $table.mood,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get quoteId => $composableBuilder(
    column: $table.quoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customQuote => $composableBuilder(
    column: $table.customQuote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get guidedPrompt => $composableBuilder(
    column: $table.guidedPrompt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$JournalEntriesTableTableOrderingComposer
    extends Composer<_$AppDatabase, $JournalEntriesTableTable> {
  $$JournalEntriesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get journalId => $composableBuilder(
    column: $table.journalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get richBodyJson => $composableBuilder(
    column: $table.richBodyJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get entryDate => $composableBuilder(
    column: $table.entryDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mood => $composableBuilder(
    column: $table.mood,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get quoteId => $composableBuilder(
    column: $table.quoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customQuote => $composableBuilder(
    column: $table.customQuote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get guidedPrompt => $composableBuilder(
    column: $table.guidedPrompt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$JournalEntriesTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $JournalEntriesTableTable> {
  $$JournalEntriesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get journalId =>
      $composableBuilder(column: $table.journalId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get richBodyJson => $composableBuilder(
    column: $table.richBodyJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get entryDate =>
      $composableBuilder(column: $table.entryDate, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<int> get mood =>
      $composableBuilder(column: $table.mood, builder: (column) => column);

  GeneratedColumn<String> get quoteId =>
      $composableBuilder(column: $table.quoteId, builder: (column) => column);

  GeneratedColumn<String> get customQuote => $composableBuilder(
    column: $table.customQuote,
    builder: (column) => column,
  );

  GeneratedColumn<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => column,
  );

  GeneratedColumn<String> get guidedPrompt => $composableBuilder(
    column: $table.guidedPrompt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$JournalEntriesTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $JournalEntriesTableTable,
          JournalEntriesTableData,
          $$JournalEntriesTableTableFilterComposer,
          $$JournalEntriesTableTableOrderingComposer,
          $$JournalEntriesTableTableAnnotationComposer,
          $$JournalEntriesTableTableCreateCompanionBuilder,
          $$JournalEntriesTableTableUpdateCompanionBuilder,
          (
            JournalEntriesTableData,
            BaseReferences<
              _$AppDatabase,
              $JournalEntriesTableTable,
              JournalEntriesTableData
            >,
          ),
          JournalEntriesTableData,
          PrefetchHooks Function()
        > {
  $$JournalEntriesTableTableTableManager(
    _$AppDatabase db,
    $JournalEntriesTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JournalEntriesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JournalEntriesTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$JournalEntriesTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> journalId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> richBodyJson = const Value.absent(),
                Value<DateTime> entryDate = const Value.absent(),
                Value<DateTime?> timestamp = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int?> mood = const Value.absent(),
                Value<String?> quoteId = const Value.absent(),
                Value<String?> customQuote = const Value.absent(),
                Value<String?> weatherIcon = const Value.absent(),
                Value<String?> guidedPrompt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => JournalEntriesTableCompanion(
                id: id,
                journalId: journalId,
                title: title,
                body: body,
                richBodyJson: richBodyJson,
                entryDate: entryDate,
                timestamp: timestamp,
                tagsJson: tagsJson,
                mood: mood,
                quoteId: quoteId,
                customQuote: customQuote,
                weatherIcon: weatherIcon,
                guidedPrompt: guidedPrompt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String journalId,
                required String title,
                required String body,
                Value<String?> richBodyJson = const Value.absent(),
                required DateTime entryDate,
                Value<DateTime?> timestamp = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int?> mood = const Value.absent(),
                Value<String?> quoteId = const Value.absent(),
                Value<String?> customQuote = const Value.absent(),
                Value<String?> weatherIcon = const Value.absent(),
                Value<String?> guidedPrompt = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => JournalEntriesTableCompanion.insert(
                id: id,
                journalId: journalId,
                title: title,
                body: body,
                richBodyJson: richBodyJson,
                entryDate: entryDate,
                timestamp: timestamp,
                tagsJson: tagsJson,
                mood: mood,
                quoteId: quoteId,
                customQuote: customQuote,
                weatherIcon: weatherIcon,
                guidedPrompt: guidedPrompt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$JournalEntriesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $JournalEntriesTableTable,
      JournalEntriesTableData,
      $$JournalEntriesTableTableFilterComposer,
      $$JournalEntriesTableTableOrderingComposer,
      $$JournalEntriesTableTableAnnotationComposer,
      $$JournalEntriesTableTableCreateCompanionBuilder,
      $$JournalEntriesTableTableUpdateCompanionBuilder,
      (
        JournalEntriesTableData,
        BaseReferences<
          _$AppDatabase,
          $JournalEntriesTableTable,
          JournalEntriesTableData
        >,
      ),
      JournalEntriesTableData,
      PrefetchHooks Function()
    >;
typedef $$TodoListsTableTableCreateCompanionBuilder =
    TodoListsTableCompanion Function({
      required String id,
      required String name,
      Value<int?> colorValue,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$TodoListsTableTableUpdateCompanionBuilder =
    TodoListsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int?> colorValue,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$TodoListsTableTableFilterComposer
    extends Composer<_$AppDatabase, $TodoListsTableTable> {
  $$TodoListsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TodoListsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TodoListsTableTable> {
  $$TodoListsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TodoListsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TodoListsTableTable> {
  $$TodoListsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$TodoListsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TodoListsTableTable,
          TodoListsTableData,
          $$TodoListsTableTableFilterComposer,
          $$TodoListsTableTableOrderingComposer,
          $$TodoListsTableTableAnnotationComposer,
          $$TodoListsTableTableCreateCompanionBuilder,
          $$TodoListsTableTableUpdateCompanionBuilder,
          (
            TodoListsTableData,
            BaseReferences<
              _$AppDatabase,
              $TodoListsTableTable,
              TodoListsTableData
            >,
          ),
          TodoListsTableData,
          PrefetchHooks Function()
        > {
  $$TodoListsTableTableTableManager(
    _$AppDatabase db,
    $TodoListsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TodoListsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TodoListsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TodoListsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> colorValue = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoListsTableCompanion(
                id: id,
                name: name,
                colorValue: colorValue,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int?> colorValue = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoListsTableCompanion.insert(
                id: id,
                name: name,
                colorValue: colorValue,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TodoListsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TodoListsTableTable,
      TodoListsTableData,
      $$TodoListsTableTableFilterComposer,
      $$TodoListsTableTableOrderingComposer,
      $$TodoListsTableTableAnnotationComposer,
      $$TodoListsTableTableCreateCompanionBuilder,
      $$TodoListsTableTableUpdateCompanionBuilder,
      (
        TodoListsTableData,
        BaseReferences<_$AppDatabase, $TodoListsTableTable, TodoListsTableData>,
      ),
      TodoListsTableData,
      PrefetchHooks Function()
    >;
typedef $$TodoTasksTableTableCreateCompanionBuilder =
    TodoTasksTableCompanion Function({
      required String id,
      required String listId,
      Value<String?> parentTaskId,
      required String title,
      Value<String?> notes,
      Value<DateTime?> dueDate,
      Value<bool> completed,
      Value<bool> starred,
      Value<int> sortOrder,
      Value<int?> preStarSortOrder,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$TodoTasksTableTableUpdateCompanionBuilder =
    TodoTasksTableCompanion Function({
      Value<String> id,
      Value<String> listId,
      Value<String?> parentTaskId,
      Value<String> title,
      Value<String?> notes,
      Value<DateTime?> dueDate,
      Value<bool> completed,
      Value<bool> starred,
      Value<int> sortOrder,
      Value<int?> preStarSortOrder,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$TodoTasksTableTableFilterComposer
    extends Composer<_$AppDatabase, $TodoTasksTableTable> {
  $$TodoTasksTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get listId => $composableBuilder(
    column: $table.listId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get preStarSortOrder => $composableBuilder(
    column: $table.preStarSortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TodoTasksTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TodoTasksTableTable> {
  $$TodoTasksTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get listId => $composableBuilder(
    column: $table.listId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get preStarSortOrder => $composableBuilder(
    column: $table.preStarSortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TodoTasksTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TodoTasksTableTable> {
  $$TodoTasksTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get listId =>
      $composableBuilder(column: $table.listId, builder: (column) => column);

  GeneratedColumn<String> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<DateTime> get dueDate =>
      $composableBuilder(column: $table.dueDate, builder: (column) => column);

  GeneratedColumn<bool> get completed =>
      $composableBuilder(column: $table.completed, builder: (column) => column);

  GeneratedColumn<bool> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get preStarSortOrder => $composableBuilder(
    column: $table.preStarSortOrder,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$TodoTasksTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TodoTasksTableTable,
          TodoTasksTableData,
          $$TodoTasksTableTableFilterComposer,
          $$TodoTasksTableTableOrderingComposer,
          $$TodoTasksTableTableAnnotationComposer,
          $$TodoTasksTableTableCreateCompanionBuilder,
          $$TodoTasksTableTableUpdateCompanionBuilder,
          (
            TodoTasksTableData,
            BaseReferences<
              _$AppDatabase,
              $TodoTasksTableTable,
              TodoTasksTableData
            >,
          ),
          TodoTasksTableData,
          PrefetchHooks Function()
        > {
  $$TodoTasksTableTableTableManager(
    _$AppDatabase db,
    $TodoTasksTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TodoTasksTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TodoTasksTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TodoTasksTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> listId = const Value.absent(),
                Value<String?> parentTaskId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<DateTime?> dueDate = const Value.absent(),
                Value<bool> completed = const Value.absent(),
                Value<bool> starred = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int?> preStarSortOrder = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoTasksTableCompanion(
                id: id,
                listId: listId,
                parentTaskId: parentTaskId,
                title: title,
                notes: notes,
                dueDate: dueDate,
                completed: completed,
                starred: starred,
                sortOrder: sortOrder,
                preStarSortOrder: preStarSortOrder,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String listId,
                Value<String?> parentTaskId = const Value.absent(),
                required String title,
                Value<String?> notes = const Value.absent(),
                Value<DateTime?> dueDate = const Value.absent(),
                Value<bool> completed = const Value.absent(),
                Value<bool> starred = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int?> preStarSortOrder = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoTasksTableCompanion.insert(
                id: id,
                listId: listId,
                parentTaskId: parentTaskId,
                title: title,
                notes: notes,
                dueDate: dueDate,
                completed: completed,
                starred: starred,
                sortOrder: sortOrder,
                preStarSortOrder: preStarSortOrder,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TodoTasksTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TodoTasksTableTable,
      TodoTasksTableData,
      $$TodoTasksTableTableFilterComposer,
      $$TodoTasksTableTableOrderingComposer,
      $$TodoTasksTableTableAnnotationComposer,
      $$TodoTasksTableTableCreateCompanionBuilder,
      $$TodoTasksTableTableUpdateCompanionBuilder,
      (
        TodoTasksTableData,
        BaseReferences<_$AppDatabase, $TodoTasksTableTable, TodoTasksTableData>,
      ),
      TodoTasksTableData,
      PrefetchHooks Function()
    >;
typedef $$CalendarEventsTableTableCreateCompanionBuilder =
    CalendarEventsTableCompanion Function({
      required String id,
      required String title,
      required DateTime start,
      required DateTime end,
      Value<bool> isFullDay,
      Value<int> colorValue,
      Value<String> notes,
      Value<String> source,
      Value<String?> externalId,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$CalendarEventsTableTableUpdateCompanionBuilder =
    CalendarEventsTableCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<DateTime> start,
      Value<DateTime> end,
      Value<bool> isFullDay,
      Value<int> colorValue,
      Value<String> notes,
      Value<String> source,
      Value<String?> externalId,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$CalendarEventsTableTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarEventsTableTable> {
  $$CalendarEventsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get start => $composableBuilder(
    column: $table.start,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get end => $composableBuilder(
    column: $table.end,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isFullDay => $composableBuilder(
    column: $table.isFullDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalendarEventsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarEventsTableTable> {
  $$CalendarEventsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get start => $composableBuilder(
    column: $table.start,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get end => $composableBuilder(
    column: $table.end,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isFullDay => $composableBuilder(
    column: $table.isFullDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalendarEventsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarEventsTableTable> {
  $$CalendarEventsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<DateTime> get start =>
      $composableBuilder(column: $table.start, builder: (column) => column);

  GeneratedColumn<DateTime> get end =>
      $composableBuilder(column: $table.end, builder: (column) => column);

  GeneratedColumn<bool> get isFullDay =>
      $composableBuilder(column: $table.isFullDay, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$CalendarEventsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarEventsTableTable,
          CalendarEventsTableData,
          $$CalendarEventsTableTableFilterComposer,
          $$CalendarEventsTableTableOrderingComposer,
          $$CalendarEventsTableTableAnnotationComposer,
          $$CalendarEventsTableTableCreateCompanionBuilder,
          $$CalendarEventsTableTableUpdateCompanionBuilder,
          (
            CalendarEventsTableData,
            BaseReferences<
              _$AppDatabase,
              $CalendarEventsTableTable,
              CalendarEventsTableData
            >,
          ),
          CalendarEventsTableData,
          PrefetchHooks Function()
        > {
  $$CalendarEventsTableTableTableManager(
    _$AppDatabase db,
    $CalendarEventsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarEventsTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalendarEventsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<DateTime> start = const Value.absent(),
                Value<DateTime> end = const Value.absent(),
                Value<bool> isFullDay = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> externalId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsTableCompanion(
                id: id,
                title: title,
                start: start,
                end: end,
                isFullDay: isFullDay,
                colorValue: colorValue,
                notes: notes,
                source: source,
                externalId: externalId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required DateTime start,
                required DateTime end,
                Value<bool> isFullDay = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> externalId = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsTableCompanion.insert(
                id: id,
                title: title,
                start: start,
                end: end,
                isFullDay: isFullDay,
                colorValue: colorValue,
                notes: notes,
                source: source,
                externalId: externalId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalendarEventsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarEventsTableTable,
      CalendarEventsTableData,
      $$CalendarEventsTableTableFilterComposer,
      $$CalendarEventsTableTableOrderingComposer,
      $$CalendarEventsTableTableAnnotationComposer,
      $$CalendarEventsTableTableCreateCompanionBuilder,
      $$CalendarEventsTableTableUpdateCompanionBuilder,
      (
        CalendarEventsTableData,
        BaseReferences<
          _$AppDatabase,
          $CalendarEventsTableTable,
          CalendarEventsTableData
        >,
      ),
      CalendarEventsTableData,
      PrefetchHooks Function()
    >;
typedef $$TrackersTableTableCreateCompanionBuilder =
    TrackersTableCompanion Function({
      required String id,
      required String name,
      required String type,
      required String cadence,
      Value<int> colorValue,
      Value<bool> showOnCalendar,
      Value<int?> integerCap,
      Value<int> defaultInt,
      Value<bool> defaultBool,
      Value<String> enumOptionsJson,
      Value<String?> defaultEnumOption,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$TrackersTableTableUpdateCompanionBuilder =
    TrackersTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> type,
      Value<String> cadence,
      Value<int> colorValue,
      Value<bool> showOnCalendar,
      Value<int?> integerCap,
      Value<int> defaultInt,
      Value<bool> defaultBool,
      Value<String> enumOptionsJson,
      Value<String?> defaultEnumOption,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$TrackersTableTableFilterComposer
    extends Composer<_$AppDatabase, $TrackersTableTable> {
  $$TrackersTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cadence => $composableBuilder(
    column: $table.cadence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get showOnCalendar => $composableBuilder(
    column: $table.showOnCalendar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get integerCap => $composableBuilder(
    column: $table.integerCap,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get defaultInt => $composableBuilder(
    column: $table.defaultInt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get defaultBool => $composableBuilder(
    column: $table.defaultBool,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get enumOptionsJson => $composableBuilder(
    column: $table.enumOptionsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get defaultEnumOption => $composableBuilder(
    column: $table.defaultEnumOption,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TrackersTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TrackersTableTable> {
  $$TrackersTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cadence => $composableBuilder(
    column: $table.cadence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get showOnCalendar => $composableBuilder(
    column: $table.showOnCalendar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get integerCap => $composableBuilder(
    column: $table.integerCap,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get defaultInt => $composableBuilder(
    column: $table.defaultInt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get defaultBool => $composableBuilder(
    column: $table.defaultBool,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get enumOptionsJson => $composableBuilder(
    column: $table.enumOptionsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get defaultEnumOption => $composableBuilder(
    column: $table.defaultEnumOption,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TrackersTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TrackersTableTable> {
  $$TrackersTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get cadence =>
      $composableBuilder(column: $table.cadence, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get showOnCalendar => $composableBuilder(
    column: $table.showOnCalendar,
    builder: (column) => column,
  );

  GeneratedColumn<int> get integerCap => $composableBuilder(
    column: $table.integerCap,
    builder: (column) => column,
  );

  GeneratedColumn<int> get defaultInt => $composableBuilder(
    column: $table.defaultInt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get defaultBool => $composableBuilder(
    column: $table.defaultBool,
    builder: (column) => column,
  );

  GeneratedColumn<String> get enumOptionsJson => $composableBuilder(
    column: $table.enumOptionsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get defaultEnumOption => $composableBuilder(
    column: $table.defaultEnumOption,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$TrackersTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TrackersTableTable,
          TrackersTableData,
          $$TrackersTableTableFilterComposer,
          $$TrackersTableTableOrderingComposer,
          $$TrackersTableTableAnnotationComposer,
          $$TrackersTableTableCreateCompanionBuilder,
          $$TrackersTableTableUpdateCompanionBuilder,
          (
            TrackersTableData,
            BaseReferences<
              _$AppDatabase,
              $TrackersTableTable,
              TrackersTableData
            >,
          ),
          TrackersTableData,
          PrefetchHooks Function()
        > {
  $$TrackersTableTableTableManager(_$AppDatabase db, $TrackersTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrackersTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrackersTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrackersTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> cadence = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<bool> showOnCalendar = const Value.absent(),
                Value<int?> integerCap = const Value.absent(),
                Value<int> defaultInt = const Value.absent(),
                Value<bool> defaultBool = const Value.absent(),
                Value<String> enumOptionsJson = const Value.absent(),
                Value<String?> defaultEnumOption = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackersTableCompanion(
                id: id,
                name: name,
                type: type,
                cadence: cadence,
                colorValue: colorValue,
                showOnCalendar: showOnCalendar,
                integerCap: integerCap,
                defaultInt: defaultInt,
                defaultBool: defaultBool,
                enumOptionsJson: enumOptionsJson,
                defaultEnumOption: defaultEnumOption,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String type,
                required String cadence,
                Value<int> colorValue = const Value.absent(),
                Value<bool> showOnCalendar = const Value.absent(),
                Value<int?> integerCap = const Value.absent(),
                Value<int> defaultInt = const Value.absent(),
                Value<bool> defaultBool = const Value.absent(),
                Value<String> enumOptionsJson = const Value.absent(),
                Value<String?> defaultEnumOption = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackersTableCompanion.insert(
                id: id,
                name: name,
                type: type,
                cadence: cadence,
                colorValue: colorValue,
                showOnCalendar: showOnCalendar,
                integerCap: integerCap,
                defaultInt: defaultInt,
                defaultBool: defaultBool,
                enumOptionsJson: enumOptionsJson,
                defaultEnumOption: defaultEnumOption,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TrackersTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TrackersTableTable,
      TrackersTableData,
      $$TrackersTableTableFilterComposer,
      $$TrackersTableTableOrderingComposer,
      $$TrackersTableTableAnnotationComposer,
      $$TrackersTableTableCreateCompanionBuilder,
      $$TrackersTableTableUpdateCompanionBuilder,
      (
        TrackersTableData,
        BaseReferences<_$AppDatabase, $TrackersTableTable, TrackersTableData>,
      ),
      TrackersTableData,
      PrefetchHooks Function()
    >;
typedef $$TrackerValuesTableTableCreateCompanionBuilder =
    TrackerValuesTableCompanion Function({
      required String id,
      required String trackerId,
      required DateTime periodStart,
      Value<int?> intValue,
      Value<bool?> boolValue,
      Value<String?> enumValue,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$TrackerValuesTableTableUpdateCompanionBuilder =
    TrackerValuesTableCompanion Function({
      Value<String> id,
      Value<String> trackerId,
      Value<DateTime> periodStart,
      Value<int?> intValue,
      Value<bool?> boolValue,
      Value<String?> enumValue,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$TrackerValuesTableTableFilterComposer
    extends Composer<_$AppDatabase, $TrackerValuesTableTable> {
  $$TrackerValuesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trackerId => $composableBuilder(
    column: $table.trackerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get intValue => $composableBuilder(
    column: $table.intValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get boolValue => $composableBuilder(
    column: $table.boolValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get enumValue => $composableBuilder(
    column: $table.enumValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TrackerValuesTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TrackerValuesTableTable> {
  $$TrackerValuesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trackerId => $composableBuilder(
    column: $table.trackerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get intValue => $composableBuilder(
    column: $table.intValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get boolValue => $composableBuilder(
    column: $table.boolValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get enumValue => $composableBuilder(
    column: $table.enumValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TrackerValuesTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TrackerValuesTableTable> {
  $$TrackerValuesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get trackerId =>
      $composableBuilder(column: $table.trackerId, builder: (column) => column);

  GeneratedColumn<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => column,
  );

  GeneratedColumn<int> get intValue =>
      $composableBuilder(column: $table.intValue, builder: (column) => column);

  GeneratedColumn<bool> get boolValue =>
      $composableBuilder(column: $table.boolValue, builder: (column) => column);

  GeneratedColumn<String> get enumValue =>
      $composableBuilder(column: $table.enumValue, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$TrackerValuesTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TrackerValuesTableTable,
          TrackerValuesTableData,
          $$TrackerValuesTableTableFilterComposer,
          $$TrackerValuesTableTableOrderingComposer,
          $$TrackerValuesTableTableAnnotationComposer,
          $$TrackerValuesTableTableCreateCompanionBuilder,
          $$TrackerValuesTableTableUpdateCompanionBuilder,
          (
            TrackerValuesTableData,
            BaseReferences<
              _$AppDatabase,
              $TrackerValuesTableTable,
              TrackerValuesTableData
            >,
          ),
          TrackerValuesTableData,
          PrefetchHooks Function()
        > {
  $$TrackerValuesTableTableTableManager(
    _$AppDatabase db,
    $TrackerValuesTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrackerValuesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrackerValuesTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrackerValuesTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> trackerId = const Value.absent(),
                Value<DateTime> periodStart = const Value.absent(),
                Value<int?> intValue = const Value.absent(),
                Value<bool?> boolValue = const Value.absent(),
                Value<String?> enumValue = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackerValuesTableCompanion(
                id: id,
                trackerId: trackerId,
                periodStart: periodStart,
                intValue: intValue,
                boolValue: boolValue,
                enumValue: enumValue,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String trackerId,
                required DateTime periodStart,
                Value<int?> intValue = const Value.absent(),
                Value<bool?> boolValue = const Value.absent(),
                Value<String?> enumValue = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackerValuesTableCompanion.insert(
                id: id,
                trackerId: trackerId,
                periodStart: periodStart,
                intValue: intValue,
                boolValue: boolValue,
                enumValue: enumValue,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TrackerValuesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TrackerValuesTableTable,
      TrackerValuesTableData,
      $$TrackerValuesTableTableFilterComposer,
      $$TrackerValuesTableTableOrderingComposer,
      $$TrackerValuesTableTableAnnotationComposer,
      $$TrackerValuesTableTableCreateCompanionBuilder,
      $$TrackerValuesTableTableUpdateCompanionBuilder,
      (
        TrackerValuesTableData,
        BaseReferences<
          _$AppDatabase,
          $TrackerValuesTableTable,
          TrackerValuesTableData
        >,
      ),
      TrackerValuesTableData,
      PrefetchHooks Function()
    >;
typedef $$RankingConfigsTableTableCreateCompanionBuilder =
    RankingConfigsTableCompanion Function({
      required String id,
      required String name,
      required String cadence,
      required int maxValue,
      Value<int> colorStart,
      Value<int> colorEnd,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$RankingConfigsTableTableUpdateCompanionBuilder =
    RankingConfigsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> cadence,
      Value<int> maxValue,
      Value<int> colorStart,
      Value<int> colorEnd,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$RankingConfigsTableTableFilterComposer
    extends Composer<_$AppDatabase, $RankingConfigsTableTable> {
  $$RankingConfigsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cadence => $composableBuilder(
    column: $table.cadence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get maxValue => $composableBuilder(
    column: $table.maxValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorStart => $composableBuilder(
    column: $table.colorStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorEnd => $composableBuilder(
    column: $table.colorEnd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RankingConfigsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $RankingConfigsTableTable> {
  $$RankingConfigsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cadence => $composableBuilder(
    column: $table.cadence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get maxValue => $composableBuilder(
    column: $table.maxValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorStart => $composableBuilder(
    column: $table.colorStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorEnd => $composableBuilder(
    column: $table.colorEnd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RankingConfigsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $RankingConfigsTableTable> {
  $$RankingConfigsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get cadence =>
      $composableBuilder(column: $table.cadence, builder: (column) => column);

  GeneratedColumn<int> get maxValue =>
      $composableBuilder(column: $table.maxValue, builder: (column) => column);

  GeneratedColumn<int> get colorStart => $composableBuilder(
    column: $table.colorStart,
    builder: (column) => column,
  );

  GeneratedColumn<int> get colorEnd =>
      $composableBuilder(column: $table.colorEnd, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$RankingConfigsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RankingConfigsTableTable,
          RankingConfigsTableData,
          $$RankingConfigsTableTableFilterComposer,
          $$RankingConfigsTableTableOrderingComposer,
          $$RankingConfigsTableTableAnnotationComposer,
          $$RankingConfigsTableTableCreateCompanionBuilder,
          $$RankingConfigsTableTableUpdateCompanionBuilder,
          (
            RankingConfigsTableData,
            BaseReferences<
              _$AppDatabase,
              $RankingConfigsTableTable,
              RankingConfigsTableData
            >,
          ),
          RankingConfigsTableData,
          PrefetchHooks Function()
        > {
  $$RankingConfigsTableTableTableManager(
    _$AppDatabase db,
    $RankingConfigsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RankingConfigsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RankingConfigsTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RankingConfigsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> cadence = const Value.absent(),
                Value<int> maxValue = const Value.absent(),
                Value<int> colorStart = const Value.absent(),
                Value<int> colorEnd = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RankingConfigsTableCompanion(
                id: id,
                name: name,
                cadence: cadence,
                maxValue: maxValue,
                colorStart: colorStart,
                colorEnd: colorEnd,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String cadence,
                required int maxValue,
                Value<int> colorStart = const Value.absent(),
                Value<int> colorEnd = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RankingConfigsTableCompanion.insert(
                id: id,
                name: name,
                cadence: cadence,
                maxValue: maxValue,
                colorStart: colorStart,
                colorEnd: colorEnd,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RankingConfigsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RankingConfigsTableTable,
      RankingConfigsTableData,
      $$RankingConfigsTableTableFilterComposer,
      $$RankingConfigsTableTableOrderingComposer,
      $$RankingConfigsTableTableAnnotationComposer,
      $$RankingConfigsTableTableCreateCompanionBuilder,
      $$RankingConfigsTableTableUpdateCompanionBuilder,
      (
        RankingConfigsTableData,
        BaseReferences<
          _$AppDatabase,
          $RankingConfigsTableTable,
          RankingConfigsTableData
        >,
      ),
      RankingConfigsTableData,
      PrefetchHooks Function()
    >;
typedef $$RankingValuesTableTableCreateCompanionBuilder =
    RankingValuesTableCompanion Function({
      required String id,
      required String configId,
      required DateTime periodStart,
      required int value,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$RankingValuesTableTableUpdateCompanionBuilder =
    RankingValuesTableCompanion Function({
      Value<String> id,
      Value<String> configId,
      Value<DateTime> periodStart,
      Value<int> value,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$RankingValuesTableTableFilterComposer
    extends Composer<_$AppDatabase, $RankingValuesTableTable> {
  $$RankingValuesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configId => $composableBuilder(
    column: $table.configId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RankingValuesTableTableOrderingComposer
    extends Composer<_$AppDatabase, $RankingValuesTableTable> {
  $$RankingValuesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configId => $composableBuilder(
    column: $table.configId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RankingValuesTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $RankingValuesTableTable> {
  $$RankingValuesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get configId =>
      $composableBuilder(column: $table.configId, builder: (column) => column);

  GeneratedColumn<DateTime> get periodStart => $composableBuilder(
    column: $table.periodStart,
    builder: (column) => column,
  );

  GeneratedColumn<int> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$RankingValuesTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RankingValuesTableTable,
          RankingValuesTableData,
          $$RankingValuesTableTableFilterComposer,
          $$RankingValuesTableTableOrderingComposer,
          $$RankingValuesTableTableAnnotationComposer,
          $$RankingValuesTableTableCreateCompanionBuilder,
          $$RankingValuesTableTableUpdateCompanionBuilder,
          (
            RankingValuesTableData,
            BaseReferences<
              _$AppDatabase,
              $RankingValuesTableTable,
              RankingValuesTableData
            >,
          ),
          RankingValuesTableData,
          PrefetchHooks Function()
        > {
  $$RankingValuesTableTableTableManager(
    _$AppDatabase db,
    $RankingValuesTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RankingValuesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RankingValuesTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RankingValuesTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> configId = const Value.absent(),
                Value<DateTime> periodStart = const Value.absent(),
                Value<int> value = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RankingValuesTableCompanion(
                id: id,
                configId: configId,
                periodStart: periodStart,
                value: value,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String configId,
                required DateTime periodStart,
                required int value,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RankingValuesTableCompanion.insert(
                id: id,
                configId: configId,
                periodStart: periodStart,
                value: value,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RankingValuesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RankingValuesTableTable,
      RankingValuesTableData,
      $$RankingValuesTableTableFilterComposer,
      $$RankingValuesTableTableOrderingComposer,
      $$RankingValuesTableTableAnnotationComposer,
      $$RankingValuesTableTableCreateCompanionBuilder,
      $$RankingValuesTableTableUpdateCompanionBuilder,
      (
        RankingValuesTableData,
        BaseReferences<
          _$AppDatabase,
          $RankingValuesTableTable,
          RankingValuesTableData
        >,
      ),
      RankingValuesTableData,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableTableCreateCompanionBuilder =
    SettingsTableCompanion Function({
      Value<int> id,
      Value<int> accentColor,
      Value<bool> weekStartsOnMonday,
      Value<bool> showQuotes,
      Value<String> journalHotkey,
      Value<String> todoHotkey,
      Value<int> rankingColorStart,
      Value<int> rankingColorEnd,
      Value<bool> timelineModeYearZero,
      Value<int?> birthYear,
      Value<bool> alertOnPeriodicPrompts,
      Value<int> alertTimeHour,
      Value<bool> hideCompletedTasks,
      Value<String?> deviceId,
      Value<String?> weatherLocationLabel,
      Value<double?> weatherLat,
      Value<double?> weatherLon,
      Value<String?> weatherIcon,
      Value<DateTime?> weatherFetchedAt,
      Value<int?> weatherConditionCode,
      Value<double?> weatherTempC,
      Value<DateTime?> weatherLocationUpdatedAt,
      Value<bool> devUseDirectOpenWeather,
      Value<String?> devOpenWeatherApiKey,
      Value<String?> weatherForecastJson,
      Value<int?> weatherChartTempColor,
      Value<int?> weatherChartRainColor,
      Value<String?> colorPaletteJson,
    });
typedef $$SettingsTableTableUpdateCompanionBuilder =
    SettingsTableCompanion Function({
      Value<int> id,
      Value<int> accentColor,
      Value<bool> weekStartsOnMonday,
      Value<bool> showQuotes,
      Value<String> journalHotkey,
      Value<String> todoHotkey,
      Value<int> rankingColorStart,
      Value<int> rankingColorEnd,
      Value<bool> timelineModeYearZero,
      Value<int?> birthYear,
      Value<bool> alertOnPeriodicPrompts,
      Value<int> alertTimeHour,
      Value<bool> hideCompletedTasks,
      Value<String?> deviceId,
      Value<String?> weatherLocationLabel,
      Value<double?> weatherLat,
      Value<double?> weatherLon,
      Value<String?> weatherIcon,
      Value<DateTime?> weatherFetchedAt,
      Value<int?> weatherConditionCode,
      Value<double?> weatherTempC,
      Value<DateTime?> weatherLocationUpdatedAt,
      Value<bool> devUseDirectOpenWeather,
      Value<String?> devOpenWeatherApiKey,
      Value<String?> weatherForecastJson,
      Value<int?> weatherChartTempColor,
      Value<int?> weatherChartRainColor,
      Value<String?> colorPaletteJson,
    });

class $$SettingsTableTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTableTable> {
  $$SettingsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get accentColor => $composableBuilder(
    column: $table.accentColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get weekStartsOnMonday => $composableBuilder(
    column: $table.weekStartsOnMonday,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get showQuotes => $composableBuilder(
    column: $table.showQuotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get journalHotkey => $composableBuilder(
    column: $table.journalHotkey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get todoHotkey => $composableBuilder(
    column: $table.todoHotkey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rankingColorStart => $composableBuilder(
    column: $table.rankingColorStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rankingColorEnd => $composableBuilder(
    column: $table.rankingColorEnd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get timelineModeYearZero => $composableBuilder(
    column: $table.timelineModeYearZero,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get birthYear => $composableBuilder(
    column: $table.birthYear,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get alertOnPeriodicPrompts => $composableBuilder(
    column: $table.alertOnPeriodicPrompts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get alertTimeHour => $composableBuilder(
    column: $table.alertTimeHour,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hideCompletedTasks => $composableBuilder(
    column: $table.hideCompletedTasks,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get weatherLocationLabel => $composableBuilder(
    column: $table.weatherLocationLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get weatherLat => $composableBuilder(
    column: $table.weatherLat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get weatherLon => $composableBuilder(
    column: $table.weatherLon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get weatherFetchedAt => $composableBuilder(
    column: $table.weatherFetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get weatherConditionCode => $composableBuilder(
    column: $table.weatherConditionCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get weatherTempC => $composableBuilder(
    column: $table.weatherTempC,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get weatherLocationUpdatedAt => $composableBuilder(
    column: $table.weatherLocationUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get devUseDirectOpenWeather => $composableBuilder(
    column: $table.devUseDirectOpenWeather,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get devOpenWeatherApiKey => $composableBuilder(
    column: $table.devOpenWeatherApiKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get weatherForecastJson => $composableBuilder(
    column: $table.weatherForecastJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get weatherChartTempColor => $composableBuilder(
    column: $table.weatherChartTempColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get weatherChartRainColor => $composableBuilder(
    column: $table.weatherChartRainColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get colorPaletteJson => $composableBuilder(
    column: $table.colorPaletteJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTableTable> {
  $$SettingsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get accentColor => $composableBuilder(
    column: $table.accentColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get weekStartsOnMonday => $composableBuilder(
    column: $table.weekStartsOnMonday,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get showQuotes => $composableBuilder(
    column: $table.showQuotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get journalHotkey => $composableBuilder(
    column: $table.journalHotkey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get todoHotkey => $composableBuilder(
    column: $table.todoHotkey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rankingColorStart => $composableBuilder(
    column: $table.rankingColorStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rankingColorEnd => $composableBuilder(
    column: $table.rankingColorEnd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get timelineModeYearZero => $composableBuilder(
    column: $table.timelineModeYearZero,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get birthYear => $composableBuilder(
    column: $table.birthYear,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get alertOnPeriodicPrompts => $composableBuilder(
    column: $table.alertOnPeriodicPrompts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get alertTimeHour => $composableBuilder(
    column: $table.alertTimeHour,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hideCompletedTasks => $composableBuilder(
    column: $table.hideCompletedTasks,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get weatherLocationLabel => $composableBuilder(
    column: $table.weatherLocationLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get weatherLat => $composableBuilder(
    column: $table.weatherLat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get weatherLon => $composableBuilder(
    column: $table.weatherLon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get weatherFetchedAt => $composableBuilder(
    column: $table.weatherFetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get weatherConditionCode => $composableBuilder(
    column: $table.weatherConditionCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get weatherTempC => $composableBuilder(
    column: $table.weatherTempC,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get weatherLocationUpdatedAt => $composableBuilder(
    column: $table.weatherLocationUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get devUseDirectOpenWeather => $composableBuilder(
    column: $table.devUseDirectOpenWeather,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get devOpenWeatherApiKey => $composableBuilder(
    column: $table.devOpenWeatherApiKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get weatherForecastJson => $composableBuilder(
    column: $table.weatherForecastJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get weatherChartTempColor => $composableBuilder(
    column: $table.weatherChartTempColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get weatherChartRainColor => $composableBuilder(
    column: $table.weatherChartRainColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get colorPaletteJson => $composableBuilder(
    column: $table.colorPaletteJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTableTable> {
  $$SettingsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get accentColor => $composableBuilder(
    column: $table.accentColor,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get weekStartsOnMonday => $composableBuilder(
    column: $table.weekStartsOnMonday,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get showQuotes => $composableBuilder(
    column: $table.showQuotes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get journalHotkey => $composableBuilder(
    column: $table.journalHotkey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get todoHotkey => $composableBuilder(
    column: $table.todoHotkey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get rankingColorStart => $composableBuilder(
    column: $table.rankingColorStart,
    builder: (column) => column,
  );

  GeneratedColumn<int> get rankingColorEnd => $composableBuilder(
    column: $table.rankingColorEnd,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get timelineModeYearZero => $composableBuilder(
    column: $table.timelineModeYearZero,
    builder: (column) => column,
  );

  GeneratedColumn<int> get birthYear =>
      $composableBuilder(column: $table.birthYear, builder: (column) => column);

  GeneratedColumn<bool> get alertOnPeriodicPrompts => $composableBuilder(
    column: $table.alertOnPeriodicPrompts,
    builder: (column) => column,
  );

  GeneratedColumn<int> get alertTimeHour => $composableBuilder(
    column: $table.alertTimeHour,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hideCompletedTasks => $composableBuilder(
    column: $table.hideCompletedTasks,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get weatherLocationLabel => $composableBuilder(
    column: $table.weatherLocationLabel,
    builder: (column) => column,
  );

  GeneratedColumn<double> get weatherLat => $composableBuilder(
    column: $table.weatherLat,
    builder: (column) => column,
  );

  GeneratedColumn<double> get weatherLon => $composableBuilder(
    column: $table.weatherLon,
    builder: (column) => column,
  );

  GeneratedColumn<String> get weatherIcon => $composableBuilder(
    column: $table.weatherIcon,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get weatherFetchedAt => $composableBuilder(
    column: $table.weatherFetchedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get weatherConditionCode => $composableBuilder(
    column: $table.weatherConditionCode,
    builder: (column) => column,
  );

  GeneratedColumn<double> get weatherTempC => $composableBuilder(
    column: $table.weatherTempC,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get weatherLocationUpdatedAt => $composableBuilder(
    column: $table.weatherLocationUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get devUseDirectOpenWeather => $composableBuilder(
    column: $table.devUseDirectOpenWeather,
    builder: (column) => column,
  );

  GeneratedColumn<String> get devOpenWeatherApiKey => $composableBuilder(
    column: $table.devOpenWeatherApiKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get weatherForecastJson => $composableBuilder(
    column: $table.weatherForecastJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get weatherChartTempColor => $composableBuilder(
    column: $table.weatherChartTempColor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get weatherChartRainColor => $composableBuilder(
    column: $table.weatherChartRainColor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get colorPaletteJson => $composableBuilder(
    column: $table.colorPaletteJson,
    builder: (column) => column,
  );
}

class $$SettingsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTableTable,
          SettingsTableData,
          $$SettingsTableTableFilterComposer,
          $$SettingsTableTableOrderingComposer,
          $$SettingsTableTableAnnotationComposer,
          $$SettingsTableTableCreateCompanionBuilder,
          $$SettingsTableTableUpdateCompanionBuilder,
          (
            SettingsTableData,
            BaseReferences<
              _$AppDatabase,
              $SettingsTableTable,
              SettingsTableData
            >,
          ),
          SettingsTableData,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableTableManager(_$AppDatabase db, $SettingsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accentColor = const Value.absent(),
                Value<bool> weekStartsOnMonday = const Value.absent(),
                Value<bool> showQuotes = const Value.absent(),
                Value<String> journalHotkey = const Value.absent(),
                Value<String> todoHotkey = const Value.absent(),
                Value<int> rankingColorStart = const Value.absent(),
                Value<int> rankingColorEnd = const Value.absent(),
                Value<bool> timelineModeYearZero = const Value.absent(),
                Value<int?> birthYear = const Value.absent(),
                Value<bool> alertOnPeriodicPrompts = const Value.absent(),
                Value<int> alertTimeHour = const Value.absent(),
                Value<bool> hideCompletedTasks = const Value.absent(),
                Value<String?> deviceId = const Value.absent(),
                Value<String?> weatherLocationLabel = const Value.absent(),
                Value<double?> weatherLat = const Value.absent(),
                Value<double?> weatherLon = const Value.absent(),
                Value<String?> weatherIcon = const Value.absent(),
                Value<DateTime?> weatherFetchedAt = const Value.absent(),
                Value<int?> weatherConditionCode = const Value.absent(),
                Value<double?> weatherTempC = const Value.absent(),
                Value<DateTime?> weatherLocationUpdatedAt =
                    const Value.absent(),
                Value<bool> devUseDirectOpenWeather = const Value.absent(),
                Value<String?> devOpenWeatherApiKey = const Value.absent(),
                Value<String?> weatherForecastJson = const Value.absent(),
                Value<int?> weatherChartTempColor = const Value.absent(),
                Value<int?> weatherChartRainColor = const Value.absent(),
                Value<String?> colorPaletteJson = const Value.absent(),
              }) => SettingsTableCompanion(
                id: id,
                accentColor: accentColor,
                weekStartsOnMonday: weekStartsOnMonday,
                showQuotes: showQuotes,
                journalHotkey: journalHotkey,
                todoHotkey: todoHotkey,
                rankingColorStart: rankingColorStart,
                rankingColorEnd: rankingColorEnd,
                timelineModeYearZero: timelineModeYearZero,
                birthYear: birthYear,
                alertOnPeriodicPrompts: alertOnPeriodicPrompts,
                alertTimeHour: alertTimeHour,
                hideCompletedTasks: hideCompletedTasks,
                deviceId: deviceId,
                weatherLocationLabel: weatherLocationLabel,
                weatherLat: weatherLat,
                weatherLon: weatherLon,
                weatherIcon: weatherIcon,
                weatherFetchedAt: weatherFetchedAt,
                weatherConditionCode: weatherConditionCode,
                weatherTempC: weatherTempC,
                weatherLocationUpdatedAt: weatherLocationUpdatedAt,
                devUseDirectOpenWeather: devUseDirectOpenWeather,
                devOpenWeatherApiKey: devOpenWeatherApiKey,
                weatherForecastJson: weatherForecastJson,
                weatherChartTempColor: weatherChartTempColor,
                weatherChartRainColor: weatherChartRainColor,
                colorPaletteJson: colorPaletteJson,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accentColor = const Value.absent(),
                Value<bool> weekStartsOnMonday = const Value.absent(),
                Value<bool> showQuotes = const Value.absent(),
                Value<String> journalHotkey = const Value.absent(),
                Value<String> todoHotkey = const Value.absent(),
                Value<int> rankingColorStart = const Value.absent(),
                Value<int> rankingColorEnd = const Value.absent(),
                Value<bool> timelineModeYearZero = const Value.absent(),
                Value<int?> birthYear = const Value.absent(),
                Value<bool> alertOnPeriodicPrompts = const Value.absent(),
                Value<int> alertTimeHour = const Value.absent(),
                Value<bool> hideCompletedTasks = const Value.absent(),
                Value<String?> deviceId = const Value.absent(),
                Value<String?> weatherLocationLabel = const Value.absent(),
                Value<double?> weatherLat = const Value.absent(),
                Value<double?> weatherLon = const Value.absent(),
                Value<String?> weatherIcon = const Value.absent(),
                Value<DateTime?> weatherFetchedAt = const Value.absent(),
                Value<int?> weatherConditionCode = const Value.absent(),
                Value<double?> weatherTempC = const Value.absent(),
                Value<DateTime?> weatherLocationUpdatedAt =
                    const Value.absent(),
                Value<bool> devUseDirectOpenWeather = const Value.absent(),
                Value<String?> devOpenWeatherApiKey = const Value.absent(),
                Value<String?> weatherForecastJson = const Value.absent(),
                Value<int?> weatherChartTempColor = const Value.absent(),
                Value<int?> weatherChartRainColor = const Value.absent(),
                Value<String?> colorPaletteJson = const Value.absent(),
              }) => SettingsTableCompanion.insert(
                id: id,
                accentColor: accentColor,
                weekStartsOnMonday: weekStartsOnMonday,
                showQuotes: showQuotes,
                journalHotkey: journalHotkey,
                todoHotkey: todoHotkey,
                rankingColorStart: rankingColorStart,
                rankingColorEnd: rankingColorEnd,
                timelineModeYearZero: timelineModeYearZero,
                birthYear: birthYear,
                alertOnPeriodicPrompts: alertOnPeriodicPrompts,
                alertTimeHour: alertTimeHour,
                hideCompletedTasks: hideCompletedTasks,
                deviceId: deviceId,
                weatherLocationLabel: weatherLocationLabel,
                weatherLat: weatherLat,
                weatherLon: weatherLon,
                weatherIcon: weatherIcon,
                weatherFetchedAt: weatherFetchedAt,
                weatherConditionCode: weatherConditionCode,
                weatherTempC: weatherTempC,
                weatherLocationUpdatedAt: weatherLocationUpdatedAt,
                devUseDirectOpenWeather: devUseDirectOpenWeather,
                devOpenWeatherApiKey: devOpenWeatherApiKey,
                weatherForecastJson: weatherForecastJson,
                weatherChartTempColor: weatherChartTempColor,
                weatherChartRainColor: weatherChartRainColor,
                colorPaletteJson: colorPaletteJson,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTableTable,
      SettingsTableData,
      $$SettingsTableTableFilterComposer,
      $$SettingsTableTableOrderingComposer,
      $$SettingsTableTableAnnotationComposer,
      $$SettingsTableTableCreateCompanionBuilder,
      $$SettingsTableTableUpdateCompanionBuilder,
      (
        SettingsTableData,
        BaseReferences<_$AppDatabase, $SettingsTableTable, SettingsTableData>,
      ),
      SettingsTableData,
      PrefetchHooks Function()
    >;
typedef $$TagColorsTableTableCreateCompanionBuilder =
    TagColorsTableCompanion Function({
      required String tag,
      required int colorValue,
      Value<int> rowid,
    });
typedef $$TagColorsTableTableUpdateCompanionBuilder =
    TagColorsTableCompanion Function({
      Value<String> tag,
      Value<int> colorValue,
      Value<int> rowid,
    });

class $$TagColorsTableTableFilterComposer
    extends Composer<_$AppDatabase, $TagColorsTableTable> {
  $$TagColorsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tag => $composableBuilder(
    column: $table.tag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TagColorsTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TagColorsTableTable> {
  $$TagColorsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tag => $composableBuilder(
    column: $table.tag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TagColorsTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TagColorsTableTable> {
  $$TagColorsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tag =>
      $composableBuilder(column: $table.tag, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );
}

class $$TagColorsTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TagColorsTableTable,
          TagColorsTableData,
          $$TagColorsTableTableFilterComposer,
          $$TagColorsTableTableOrderingComposer,
          $$TagColorsTableTableAnnotationComposer,
          $$TagColorsTableTableCreateCompanionBuilder,
          $$TagColorsTableTableUpdateCompanionBuilder,
          (
            TagColorsTableData,
            BaseReferences<
              _$AppDatabase,
              $TagColorsTableTable,
              TagColorsTableData
            >,
          ),
          TagColorsTableData,
          PrefetchHooks Function()
        > {
  $$TagColorsTableTableTableManager(
    _$AppDatabase db,
    $TagColorsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagColorsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagColorsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagColorsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> tag = const Value.absent(),
                Value<int> colorValue = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagColorsTableCompanion(
                tag: tag,
                colorValue: colorValue,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String tag,
                required int colorValue,
                Value<int> rowid = const Value.absent(),
              }) => TagColorsTableCompanion.insert(
                tag: tag,
                colorValue: colorValue,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TagColorsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TagColorsTableTable,
      TagColorsTableData,
      $$TagColorsTableTableFilterComposer,
      $$TagColorsTableTableOrderingComposer,
      $$TagColorsTableTableAnnotationComposer,
      $$TagColorsTableTableCreateCompanionBuilder,
      $$TagColorsTableTableUpdateCompanionBuilder,
      (
        TagColorsTableData,
        BaseReferences<_$AppDatabase, $TagColorsTableTable, TagColorsTableData>,
      ),
      TagColorsTableData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$JournalsTableTableTableManager get journalsTable =>
      $$JournalsTableTableTableManager(_db, _db.journalsTable);
  $$JournalEntriesTableTableTableManager get journalEntriesTable =>
      $$JournalEntriesTableTableTableManager(_db, _db.journalEntriesTable);
  $$TodoListsTableTableTableManager get todoListsTable =>
      $$TodoListsTableTableTableManager(_db, _db.todoListsTable);
  $$TodoTasksTableTableTableManager get todoTasksTable =>
      $$TodoTasksTableTableTableManager(_db, _db.todoTasksTable);
  $$CalendarEventsTableTableTableManager get calendarEventsTable =>
      $$CalendarEventsTableTableTableManager(_db, _db.calendarEventsTable);
  $$TrackersTableTableTableManager get trackersTable =>
      $$TrackersTableTableTableManager(_db, _db.trackersTable);
  $$TrackerValuesTableTableTableManager get trackerValuesTable =>
      $$TrackerValuesTableTableTableManager(_db, _db.trackerValuesTable);
  $$RankingConfigsTableTableTableManager get rankingConfigsTable =>
      $$RankingConfigsTableTableTableManager(_db, _db.rankingConfigsTable);
  $$RankingValuesTableTableTableManager get rankingValuesTable =>
      $$RankingValuesTableTableTableManager(_db, _db.rankingValuesTable);
  $$SettingsTableTableTableManager get settingsTable =>
      $$SettingsTableTableTableManager(_db, _db.settingsTable);
  $$TagColorsTableTableTableManager get tagColorsTable =>
      $$TagColorsTableTableTableManager(_db, _db.tagColorsTable);
}
