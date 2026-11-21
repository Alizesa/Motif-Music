// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_database.dart';

// ignore_for_file: type=lint
class LibraryRoots extends Table with TableInfo<LibraryRoots, LibraryRoot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  LibraryRoots(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (platform IN (\'windows\', \'android\'))',
  );
  static const VerificationMeta _locationKeyMeta = const VerificationMeta(
    'locationKey',
  );
  late final GeneratedColumn<String> locationKey = GeneratedColumn<String>(
    'location_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(location_key) > 0)',
  );
  static const VerificationMeta _locatorMeta = const VerificationMeta(
    'locator',
  );
  late final GeneratedColumn<String> locator = GeneratedColumn<String>(
    'locator',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(locator) > 0)',
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _isAccessibleMeta = const VerificationMeta(
    'isAccessible',
  );
  late final GeneratedColumn<int> isAccessible = GeneratedColumn<int>(
    'is_accessible',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 1 CHECK (is_accessible IN (0, 1))',
    defaultValue: const CustomExpression('1'),
  );
  static const VerificationMeta _scanGenerationMeta = const VerificationMeta(
    'scanGeneration',
  );
  late final GeneratedColumn<int> scanGeneration = GeneratedColumn<int>(
    'scan_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _activeGenerationMeta = const VerificationMeta(
    'activeGeneration',
  );
  late final GeneratedColumn<int> activeGeneration = GeneratedColumn<int>(
    'active_generation',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _lastScanStateMeta = const VerificationMeta(
    'lastScanState',
  );
  late final GeneratedColumn<String> lastScanState = GeneratedColumn<String>(
    'last_scan_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'never\' CHECK (last_scan_state IN (\'never\', \'running\', \'complete\', \'failed\', \'interrupted\'))',
    defaultValue: const CustomExpression('\'never\''),
  );
  static const VerificationMeta _lastCompletedMsMeta = const VerificationMeta(
    'lastCompletedMs',
  );
  late final GeneratedColumn<int> lastCompletedMs = GeneratedColumn<int>(
    'last_completed_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    platform,
    locationKey,
    locator,
    displayName,
    isAccessible,
    scanGeneration,
    activeGeneration,
    lastScanState,
    lastCompletedMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_roots';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryRoot> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    } else if (isInserting) {
      context.missing(_platformMeta);
    }
    if (data.containsKey('location_key')) {
      context.handle(
        _locationKeyMeta,
        locationKey.isAcceptableOrUnknown(
          data['location_key']!,
          _locationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_locationKeyMeta);
    }
    if (data.containsKey('locator')) {
      context.handle(
        _locatorMeta,
        locator.isAcceptableOrUnknown(data['locator']!, _locatorMeta),
      );
    } else if (isInserting) {
      context.missing(_locatorMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('is_accessible')) {
      context.handle(
        _isAccessibleMeta,
        isAccessible.isAcceptableOrUnknown(
          data['is_accessible']!,
          _isAccessibleMeta,
        ),
      );
    }
    if (data.containsKey('scan_generation')) {
      context.handle(
        _scanGenerationMeta,
        scanGeneration.isAcceptableOrUnknown(
          data['scan_generation']!,
          _scanGenerationMeta,
        ),
      );
    }
    if (data.containsKey('active_generation')) {
      context.handle(
        _activeGenerationMeta,
        activeGeneration.isAcceptableOrUnknown(
          data['active_generation']!,
          _activeGenerationMeta,
        ),
      );
    }
    if (data.containsKey('last_scan_state')) {
      context.handle(
        _lastScanStateMeta,
        lastScanState.isAcceptableOrUnknown(
          data['last_scan_state']!,
          _lastScanStateMeta,
        ),
      );
    }
    if (data.containsKey('last_completed_ms')) {
      context.handle(
        _lastCompletedMsMeta,
        lastCompletedMs.isAcceptableOrUnknown(
          data['last_completed_ms']!,
          _lastCompletedMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {platform, locationKey},
  ];
  @override
  LibraryRoot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryRoot(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      locationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_key'],
      )!,
      locator: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}locator'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      isAccessible: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_accessible'],
      )!,
      scanGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scan_generation'],
      )!,
      activeGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}active_generation'],
      ),
      lastScanState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_scan_state'],
      )!,
      lastCompletedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_completed_ms'],
      ),
    );
  }

  @override
  LibraryRoots createAlias(String alias) {
    return LibraryRoots(attachedDatabase, alias);
  }

  @override
  List<String> get customConstraints => const [
    'UNIQUE(platform, location_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class LibraryRoot extends DataClass implements Insertable<LibraryRoot> {
  final int id;
  final String platform;
  final String locationKey;
  final String locator;
  final String displayName;
  final int isAccessible;
  final int scanGeneration;
  final int? activeGeneration;
  final String lastScanState;
  final int? lastCompletedMs;
  const LibraryRoot({
    required this.id,
    required this.platform,
    required this.locationKey,
    required this.locator,
    required this.displayName,
    required this.isAccessible,
    required this.scanGeneration,
    this.activeGeneration,
    required this.lastScanState,
    this.lastCompletedMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['platform'] = Variable<String>(platform);
    map['location_key'] = Variable<String>(locationKey);
    map['locator'] = Variable<String>(locator);
    map['display_name'] = Variable<String>(displayName);
    map['is_accessible'] = Variable<int>(isAccessible);
    map['scan_generation'] = Variable<int>(scanGeneration);
    if (!nullToAbsent || activeGeneration != null) {
      map['active_generation'] = Variable<int>(activeGeneration);
    }
    map['last_scan_state'] = Variable<String>(lastScanState);
    if (!nullToAbsent || lastCompletedMs != null) {
      map['last_completed_ms'] = Variable<int>(lastCompletedMs);
    }
    return map;
  }

  LibraryRootsCompanion toCompanion(bool nullToAbsent) {
    return LibraryRootsCompanion(
      id: Value(id),
      platform: Value(platform),
      locationKey: Value(locationKey),
      locator: Value(locator),
      displayName: Value(displayName),
      isAccessible: Value(isAccessible),
      scanGeneration: Value(scanGeneration),
      activeGeneration: activeGeneration == null && nullToAbsent
          ? const Value.absent()
          : Value(activeGeneration),
      lastScanState: Value(lastScanState),
      lastCompletedMs: lastCompletedMs == null && nullToAbsent
          ? const Value.absent()
          : Value(lastCompletedMs),
    );
  }

  factory LibraryRoot.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryRoot(
      id: serializer.fromJson<int>(json['id']),
      platform: serializer.fromJson<String>(json['platform']),
      locationKey: serializer.fromJson<String>(json['location_key']),
      locator: serializer.fromJson<String>(json['locator']),
      displayName: serializer.fromJson<String>(json['display_name']),
      isAccessible: serializer.fromJson<int>(json['is_accessible']),
      scanGeneration: serializer.fromJson<int>(json['scan_generation']),
      activeGeneration: serializer.fromJson<int?>(json['active_generation']),
      lastScanState: serializer.fromJson<String>(json['last_scan_state']),
      lastCompletedMs: serializer.fromJson<int?>(json['last_completed_ms']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'platform': serializer.toJson<String>(platform),
      'location_key': serializer.toJson<String>(locationKey),
      'locator': serializer.toJson<String>(locator),
      'display_name': serializer.toJson<String>(displayName),
      'is_accessible': serializer.toJson<int>(isAccessible),
      'scan_generation': serializer.toJson<int>(scanGeneration),
      'active_generation': serializer.toJson<int?>(activeGeneration),
      'last_scan_state': serializer.toJson<String>(lastScanState),
      'last_completed_ms': serializer.toJson<int?>(lastCompletedMs),
    };
  }

  LibraryRoot copyWith({
    int? id,
    String? platform,
    String? locationKey,
    String? locator,
    String? displayName,
    int? isAccessible,
    int? scanGeneration,
    Value<int?> activeGeneration = const Value.absent(),
    String? lastScanState,
    Value<int?> lastCompletedMs = const Value.absent(),
  }) => LibraryRoot(
    id: id ?? this.id,
    platform: platform ?? this.platform,
    locationKey: locationKey ?? this.locationKey,
    locator: locator ?? this.locator,
    displayName: displayName ?? this.displayName,
    isAccessible: isAccessible ?? this.isAccessible,
    scanGeneration: scanGeneration ?? this.scanGeneration,
    activeGeneration: activeGeneration.present
        ? activeGeneration.value
        : this.activeGeneration,
    lastScanState: lastScanState ?? this.lastScanState,
    lastCompletedMs: lastCompletedMs.present
        ? lastCompletedMs.value
        : this.lastCompletedMs,
  );
  LibraryRoot copyWithCompanion(LibraryRootsCompanion data) {
    return LibraryRoot(
      id: data.id.present ? data.id.value : this.id,
      platform: data.platform.present ? data.platform.value : this.platform,
      locationKey: data.locationKey.present
          ? data.locationKey.value
          : this.locationKey,
      locator: data.locator.present ? data.locator.value : this.locator,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      isAccessible: data.isAccessible.present
          ? data.isAccessible.value
          : this.isAccessible,
      scanGeneration: data.scanGeneration.present
          ? data.scanGeneration.value
          : this.scanGeneration,
      activeGeneration: data.activeGeneration.present
          ? data.activeGeneration.value
          : this.activeGeneration,
      lastScanState: data.lastScanState.present
          ? data.lastScanState.value
          : this.lastScanState,
      lastCompletedMs: data.lastCompletedMs.present
          ? data.lastCompletedMs.value
          : this.lastCompletedMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryRoot(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('locationKey: $locationKey, ')
          ..write('locator: $locator, ')
          ..write('displayName: $displayName, ')
          ..write('isAccessible: $isAccessible, ')
          ..write('scanGeneration: $scanGeneration, ')
          ..write('activeGeneration: $activeGeneration, ')
          ..write('lastScanState: $lastScanState, ')
          ..write('lastCompletedMs: $lastCompletedMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    platform,
    locationKey,
    locator,
    displayName,
    isAccessible,
    scanGeneration,
    activeGeneration,
    lastScanState,
    lastCompletedMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryRoot &&
          other.id == this.id &&
          other.platform == this.platform &&
          other.locationKey == this.locationKey &&
          other.locator == this.locator &&
          other.displayName == this.displayName &&
          other.isAccessible == this.isAccessible &&
          other.scanGeneration == this.scanGeneration &&
          other.activeGeneration == this.activeGeneration &&
          other.lastScanState == this.lastScanState &&
          other.lastCompletedMs == this.lastCompletedMs);
}

class LibraryRootsCompanion extends UpdateCompanion<LibraryRoot> {
  final Value<int> id;
  final Value<String> platform;
  final Value<String> locationKey;
  final Value<String> locator;
  final Value<String> displayName;
  final Value<int> isAccessible;
  final Value<int> scanGeneration;
  final Value<int?> activeGeneration;
  final Value<String> lastScanState;
  final Value<int?> lastCompletedMs;
  const LibraryRootsCompanion({
    this.id = const Value.absent(),
    this.platform = const Value.absent(),
    this.locationKey = const Value.absent(),
    this.locator = const Value.absent(),
    this.displayName = const Value.absent(),
    this.isAccessible = const Value.absent(),
    this.scanGeneration = const Value.absent(),
    this.activeGeneration = const Value.absent(),
    this.lastScanState = const Value.absent(),
    this.lastCompletedMs = const Value.absent(),
  });
  LibraryRootsCompanion.insert({
    this.id = const Value.absent(),
    required String platform,
    required String locationKey,
    required String locator,
    required String displayName,
    this.isAccessible = const Value.absent(),
    this.scanGeneration = const Value.absent(),
    this.activeGeneration = const Value.absent(),
    this.lastScanState = const Value.absent(),
    this.lastCompletedMs = const Value.absent(),
  }) : platform = Value(platform),
       locationKey = Value(locationKey),
       locator = Value(locator),
       displayName = Value(displayName);
  static Insertable<LibraryRoot> custom({
    Expression<int>? id,
    Expression<String>? platform,
    Expression<String>? locationKey,
    Expression<String>? locator,
    Expression<String>? displayName,
    Expression<int>? isAccessible,
    Expression<int>? scanGeneration,
    Expression<int>? activeGeneration,
    Expression<String>? lastScanState,
    Expression<int>? lastCompletedMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (platform != null) 'platform': platform,
      if (locationKey != null) 'location_key': locationKey,
      if (locator != null) 'locator': locator,
      if (displayName != null) 'display_name': displayName,
      if (isAccessible != null) 'is_accessible': isAccessible,
      if (scanGeneration != null) 'scan_generation': scanGeneration,
      if (activeGeneration != null) 'active_generation': activeGeneration,
      if (lastScanState != null) 'last_scan_state': lastScanState,
      if (lastCompletedMs != null) 'last_completed_ms': lastCompletedMs,
    });
  }

  LibraryRootsCompanion copyWith({
    Value<int>? id,
    Value<String>? platform,
    Value<String>? locationKey,
    Value<String>? locator,
    Value<String>? displayName,
    Value<int>? isAccessible,
    Value<int>? scanGeneration,
    Value<int?>? activeGeneration,
    Value<String>? lastScanState,
    Value<int?>? lastCompletedMs,
  }) {
    return LibraryRootsCompanion(
      id: id ?? this.id,
      platform: platform ?? this.platform,
      locationKey: locationKey ?? this.locationKey,
      locator: locator ?? this.locator,
      displayName: displayName ?? this.displayName,
      isAccessible: isAccessible ?? this.isAccessible,
      scanGeneration: scanGeneration ?? this.scanGeneration,
      activeGeneration: activeGeneration ?? this.activeGeneration,
      lastScanState: lastScanState ?? this.lastScanState,
      lastCompletedMs: lastCompletedMs ?? this.lastCompletedMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (locationKey.present) {
      map['location_key'] = Variable<String>(locationKey.value);
    }
    if (locator.present) {
      map['locator'] = Variable<String>(locator.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (isAccessible.present) {
      map['is_accessible'] = Variable<int>(isAccessible.value);
    }
    if (scanGeneration.present) {
      map['scan_generation'] = Variable<int>(scanGeneration.value);
    }
    if (activeGeneration.present) {
      map['active_generation'] = Variable<int>(activeGeneration.value);
    }
    if (lastScanState.present) {
      map['last_scan_state'] = Variable<String>(lastScanState.value);
    }
    if (lastCompletedMs.present) {
      map['last_completed_ms'] = Variable<int>(lastCompletedMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryRootsCompanion(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('locationKey: $locationKey, ')
          ..write('locator: $locator, ')
          ..write('displayName: $displayName, ')
          ..write('isAccessible: $isAccessible, ')
          ..write('scanGeneration: $scanGeneration, ')
          ..write('activeGeneration: $activeGeneration, ')
          ..write('lastScanState: $lastScanState, ')
          ..write('lastCompletedMs: $lastCompletedMs')
          ..write(')'))
        .toString();
  }
}

class LocalTracks extends Table with TableInfo<LocalTracks, LocalTrack> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  LocalTracks(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (platform IN (\'windows\', \'android\'))',
  );
  static const VerificationMeta _locationKeyMeta = const VerificationMeta(
    'locationKey',
  );
  late final GeneratedColumn<String> locationKey = GeneratedColumn<String>(
    'location_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(location_key) > 0)',
  );
  static const VerificationMeta _locatorMeta = const VerificationMeta(
    'locator',
  );
  late final GeneratedColumn<String> locator = GeneratedColumn<String>(
    'locator',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(locator) > 0)',
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (size_bytes >= 0)',
  );
  static const VerificationMeta _modifiedMsMeta = const VerificationMeta(
    'modifiedMs',
  );
  late final GeneratedColumn<int> modifiedMs = GeneratedColumn<int>(
    'modified_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
    'artist',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
    'album',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _titleKeyMeta = const VerificationMeta(
    'titleKey',
  );
  late final GeneratedColumn<String> titleKey = GeneratedColumn<String>(
    'title_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _artistKeyMeta = const VerificationMeta(
    'artistKey',
  );
  late final GeneratedColumn<String> artistKey = GeneratedColumn<String>(
    'artist_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _albumKeyMeta = const VerificationMeta(
    'albumKey',
  );
  late final GeneratedColumn<String> albumKey = GeneratedColumn<String>(
    'album_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (duration_ms > 0)',
  );
  static const VerificationMeta _containerMeta = const VerificationMeta(
    'container',
  );
  late final GeneratedColumn<String> container = GeneratedColumn<String>(
    'container',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _codecMeta = const VerificationMeta('codec');
  late final GeneratedColumn<String> codec = GeneratedColumn<String>(
    'codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _metadataStateMeta = const VerificationMeta(
    'metadataState',
  );
  late final GeneratedColumn<String> metadataState = GeneratedColumn<String>(
    'metadata_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'pending\' CHECK (metadata_state IN (\'pending\', \'ready\', \'failed\'))',
    defaultValue: const CustomExpression('\'pending\''),
  );
  static const VerificationMeta _normalizationVersionMeta =
      const VerificationMeta('normalizationVersion');
  late final GeneratedColumn<int> normalizationVersion = GeneratedColumn<int>(
    'normalization_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 1',
    defaultValue: const CustomExpression('1'),
  );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  late final GeneratedColumn<int> revision = GeneratedColumn<int>(
    'revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 1',
    defaultValue: const CustomExpression('1'),
  );
  static const VerificationMeta _isPresentMeta = const VerificationMeta(
    'isPresent',
  );
  late final GeneratedColumn<int> isPresent = GeneratedColumn<int>(
    'is_present',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 1 CHECK (is_present IN (0, 1))',
    defaultValue: const CustomExpression('1'),
  );
  static const VerificationMeta _bitrateKbpsMeta = const VerificationMeta(
    'bitrateKbps',
  );
  late final GeneratedColumn<int> bitrateKbps = GeneratedColumn<int>(
    'bitrate_kbps',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (bitrate_kbps > 0)',
  );
  static const VerificationMeta _sampleRateHzMeta = const VerificationMeta(
    'sampleRateHz',
  );
  late final GeneratedColumn<int> sampleRateHz = GeneratedColumn<int>(
    'sample_rate_hz',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (sample_rate_hz > 0)',
  );
  static const VerificationMeta _channelsMeta = const VerificationMeta(
    'channels',
  );
  late final GeneratedColumn<int> channels = GeneratedColumn<int>(
    'channels',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (channels > 0)',
  );
  static const VerificationMeta _isLosslessMeta = const VerificationMeta(
    'isLossless',
  );
  late final GeneratedColumn<int> isLossless = GeneratedColumn<int>(
    'is_lossless',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'CHECK (is_lossless IN (0, 1))',
  );
  static const VerificationMeta _qualityReadStateMeta = const VerificationMeta(
    'qualityReadState',
  );
  late final GeneratedColumn<String> qualityReadState = GeneratedColumn<String>(
    'quality_read_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'pending\' CHECK (quality_read_state IN (\'pending\', \'ready\', \'failed\'))',
    defaultValue: const CustomExpression('\'pending\''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    platform,
    locationKey,
    locator,
    fileName,
    sizeBytes,
    modifiedMs,
    title,
    artist,
    album,
    titleKey,
    artistKey,
    albumKey,
    durationMs,
    container,
    codec,
    metadataState,
    normalizationVersion,
    revision,
    isPresent,
    bitrateKbps,
    sampleRateHz,
    channels,
    isLossless,
    qualityReadState,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_tracks';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalTrack> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    } else if (isInserting) {
      context.missing(_platformMeta);
    }
    if (data.containsKey('location_key')) {
      context.handle(
        _locationKeyMeta,
        locationKey.isAcceptableOrUnknown(
          data['location_key']!,
          _locationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_locationKeyMeta);
    }
    if (data.containsKey('locator')) {
      context.handle(
        _locatorMeta,
        locator.isAcceptableOrUnknown(data['locator']!, _locatorMeta),
      );
    } else if (isInserting) {
      context.missing(_locatorMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('modified_ms')) {
      context.handle(
        _modifiedMsMeta,
        modifiedMs.isAcceptableOrUnknown(data['modified_ms']!, _modifiedMsMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('artist')) {
      context.handle(
        _artistMeta,
        artist.isAcceptableOrUnknown(data['artist']!, _artistMeta),
      );
    }
    if (data.containsKey('album')) {
      context.handle(
        _albumMeta,
        album.isAcceptableOrUnknown(data['album']!, _albumMeta),
      );
    }
    if (data.containsKey('title_key')) {
      context.handle(
        _titleKeyMeta,
        titleKey.isAcceptableOrUnknown(data['title_key']!, _titleKeyMeta),
      );
    }
    if (data.containsKey('artist_key')) {
      context.handle(
        _artistKeyMeta,
        artistKey.isAcceptableOrUnknown(data['artist_key']!, _artistKeyMeta),
      );
    }
    if (data.containsKey('album_key')) {
      context.handle(
        _albumKeyMeta,
        albumKey.isAcceptableOrUnknown(data['album_key']!, _albumKeyMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('container')) {
      context.handle(
        _containerMeta,
        container.isAcceptableOrUnknown(data['container']!, _containerMeta),
      );
    }
    if (data.containsKey('codec')) {
      context.handle(
        _codecMeta,
        codec.isAcceptableOrUnknown(data['codec']!, _codecMeta),
      );
    }
    if (data.containsKey('metadata_state')) {
      context.handle(
        _metadataStateMeta,
        metadataState.isAcceptableOrUnknown(
          data['metadata_state']!,
          _metadataStateMeta,
        ),
      );
    }
    if (data.containsKey('normalization_version')) {
      context.handle(
        _normalizationVersionMeta,
        normalizationVersion.isAcceptableOrUnknown(
          data['normalization_version']!,
          _normalizationVersionMeta,
        ),
      );
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    }
    if (data.containsKey('is_present')) {
      context.handle(
        _isPresentMeta,
        isPresent.isAcceptableOrUnknown(data['is_present']!, _isPresentMeta),
      );
    }
    if (data.containsKey('bitrate_kbps')) {
      context.handle(
        _bitrateKbpsMeta,
        bitrateKbps.isAcceptableOrUnknown(
          data['bitrate_kbps']!,
          _bitrateKbpsMeta,
        ),
      );
    }
    if (data.containsKey('sample_rate_hz')) {
      context.handle(
        _sampleRateHzMeta,
        sampleRateHz.isAcceptableOrUnknown(
          data['sample_rate_hz']!,
          _sampleRateHzMeta,
        ),
      );
    }
    if (data.containsKey('channels')) {
      context.handle(
        _channelsMeta,
        channels.isAcceptableOrUnknown(data['channels']!, _channelsMeta),
      );
    }
    if (data.containsKey('is_lossless')) {
      context.handle(
        _isLosslessMeta,
        isLossless.isAcceptableOrUnknown(data['is_lossless']!, _isLosslessMeta),
      );
    }
    if (data.containsKey('quality_read_state')) {
      context.handle(
        _qualityReadStateMeta,
        qualityReadState.isAcceptableOrUnknown(
          data['quality_read_state']!,
          _qualityReadStateMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {platform, locationKey},
  ];
  @override
  LocalTrack map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalTrack(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      locationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_key'],
      )!,
      locator: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}locator'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      ),
      modifiedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}modified_ms'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      artist: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist'],
      )!,
      album: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album'],
      )!,
      titleKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title_key'],
      )!,
      artistKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist_key'],
      )!,
      albumKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album_key'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      container: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}container'],
      ),
      codec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}codec'],
      ),
      metadataState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_state'],
      )!,
      normalizationVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}normalization_version'],
      )!,
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}revision'],
      )!,
      isPresent: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_present'],
      )!,
      bitrateKbps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bitrate_kbps'],
      ),
      sampleRateHz: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sample_rate_hz'],
      ),
      channels: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channels'],
      ),
      isLossless: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_lossless'],
      ),
      qualityReadState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quality_read_state'],
      )!,
    );
  }

  @override
  LocalTracks createAlias(String alias) {
    return LocalTracks(attachedDatabase, alias);
  }

  @override
  List<String> get customConstraints => const [
    'UNIQUE(platform, location_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class LocalTrack extends DataClass implements Insertable<LocalTrack> {
  final int id;
  final String platform;
  final String locationKey;
  final String locator;
  final String fileName;
  final int? sizeBytes;
  final int? modifiedMs;
  final String title;
  final String artist;
  final String album;
  final String titleKey;
  final String artistKey;
  final String albumKey;
  final int? durationMs;
  final String? container;
  final String? codec;
  final String metadataState;
  final int normalizationVersion;
  final int revision;
  final int isPresent;
  final int? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final int? isLossless;
  final String qualityReadState;
  const LocalTrack({
    required this.id,
    required this.platform,
    required this.locationKey,
    required this.locator,
    required this.fileName,
    this.sizeBytes,
    this.modifiedMs,
    required this.title,
    required this.artist,
    required this.album,
    required this.titleKey,
    required this.artistKey,
    required this.albumKey,
    this.durationMs,
    this.container,
    this.codec,
    required this.metadataState,
    required this.normalizationVersion,
    required this.revision,
    required this.isPresent,
    this.bitrateKbps,
    this.sampleRateHz,
    this.channels,
    this.isLossless,
    required this.qualityReadState,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['platform'] = Variable<String>(platform);
    map['location_key'] = Variable<String>(locationKey);
    map['locator'] = Variable<String>(locator);
    map['file_name'] = Variable<String>(fileName);
    if (!nullToAbsent || sizeBytes != null) {
      map['size_bytes'] = Variable<int>(sizeBytes);
    }
    if (!nullToAbsent || modifiedMs != null) {
      map['modified_ms'] = Variable<int>(modifiedMs);
    }
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    map['title_key'] = Variable<String>(titleKey);
    map['artist_key'] = Variable<String>(artistKey);
    map['album_key'] = Variable<String>(albumKey);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || container != null) {
      map['container'] = Variable<String>(container);
    }
    if (!nullToAbsent || codec != null) {
      map['codec'] = Variable<String>(codec);
    }
    map['metadata_state'] = Variable<String>(metadataState);
    map['normalization_version'] = Variable<int>(normalizationVersion);
    map['revision'] = Variable<int>(revision);
    map['is_present'] = Variable<int>(isPresent);
    if (!nullToAbsent || bitrateKbps != null) {
      map['bitrate_kbps'] = Variable<int>(bitrateKbps);
    }
    if (!nullToAbsent || sampleRateHz != null) {
      map['sample_rate_hz'] = Variable<int>(sampleRateHz);
    }
    if (!nullToAbsent || channels != null) {
      map['channels'] = Variable<int>(channels);
    }
    if (!nullToAbsent || isLossless != null) {
      map['is_lossless'] = Variable<int>(isLossless);
    }
    map['quality_read_state'] = Variable<String>(qualityReadState);
    return map;
  }

  LocalTracksCompanion toCompanion(bool nullToAbsent) {
    return LocalTracksCompanion(
      id: Value(id),
      platform: Value(platform),
      locationKey: Value(locationKey),
      locator: Value(locator),
      fileName: Value(fileName),
      sizeBytes: sizeBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(sizeBytes),
      modifiedMs: modifiedMs == null && nullToAbsent
          ? const Value.absent()
          : Value(modifiedMs),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      titleKey: Value(titleKey),
      artistKey: Value(artistKey),
      albumKey: Value(albumKey),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      container: container == null && nullToAbsent
          ? const Value.absent()
          : Value(container),
      codec: codec == null && nullToAbsent
          ? const Value.absent()
          : Value(codec),
      metadataState: Value(metadataState),
      normalizationVersion: Value(normalizationVersion),
      revision: Value(revision),
      isPresent: Value(isPresent),
      bitrateKbps: bitrateKbps == null && nullToAbsent
          ? const Value.absent()
          : Value(bitrateKbps),
      sampleRateHz: sampleRateHz == null && nullToAbsent
          ? const Value.absent()
          : Value(sampleRateHz),
      channels: channels == null && nullToAbsent
          ? const Value.absent()
          : Value(channels),
      isLossless: isLossless == null && nullToAbsent
          ? const Value.absent()
          : Value(isLossless),
      qualityReadState: Value(qualityReadState),
    );
  }

  factory LocalTrack.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalTrack(
      id: serializer.fromJson<int>(json['id']),
      platform: serializer.fromJson<String>(json['platform']),
      locationKey: serializer.fromJson<String>(json['location_key']),
      locator: serializer.fromJson<String>(json['locator']),
      fileName: serializer.fromJson<String>(json['file_name']),
      sizeBytes: serializer.fromJson<int?>(json['size_bytes']),
      modifiedMs: serializer.fromJson<int?>(json['modified_ms']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      titleKey: serializer.fromJson<String>(json['title_key']),
      artistKey: serializer.fromJson<String>(json['artist_key']),
      albumKey: serializer.fromJson<String>(json['album_key']),
      durationMs: serializer.fromJson<int?>(json['duration_ms']),
      container: serializer.fromJson<String?>(json['container']),
      codec: serializer.fromJson<String?>(json['codec']),
      metadataState: serializer.fromJson<String>(json['metadata_state']),
      normalizationVersion: serializer.fromJson<int>(
        json['normalization_version'],
      ),
      revision: serializer.fromJson<int>(json['revision']),
      isPresent: serializer.fromJson<int>(json['is_present']),
      bitrateKbps: serializer.fromJson<int?>(json['bitrate_kbps']),
      sampleRateHz: serializer.fromJson<int?>(json['sample_rate_hz']),
      channels: serializer.fromJson<int?>(json['channels']),
      isLossless: serializer.fromJson<int?>(json['is_lossless']),
      qualityReadState: serializer.fromJson<String>(json['quality_read_state']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'platform': serializer.toJson<String>(platform),
      'location_key': serializer.toJson<String>(locationKey),
      'locator': serializer.toJson<String>(locator),
      'file_name': serializer.toJson<String>(fileName),
      'size_bytes': serializer.toJson<int?>(sizeBytes),
      'modified_ms': serializer.toJson<int?>(modifiedMs),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'title_key': serializer.toJson<String>(titleKey),
      'artist_key': serializer.toJson<String>(artistKey),
      'album_key': serializer.toJson<String>(albumKey),
      'duration_ms': serializer.toJson<int?>(durationMs),
      'container': serializer.toJson<String?>(container),
      'codec': serializer.toJson<String?>(codec),
      'metadata_state': serializer.toJson<String>(metadataState),
      'normalization_version': serializer.toJson<int>(normalizationVersion),
      'revision': serializer.toJson<int>(revision),
      'is_present': serializer.toJson<int>(isPresent),
      'bitrate_kbps': serializer.toJson<int?>(bitrateKbps),
      'sample_rate_hz': serializer.toJson<int?>(sampleRateHz),
      'channels': serializer.toJson<int?>(channels),
      'is_lossless': serializer.toJson<int?>(isLossless),
      'quality_read_state': serializer.toJson<String>(qualityReadState),
    };
  }

  LocalTrack copyWith({
    int? id,
    String? platform,
    String? locationKey,
    String? locator,
    String? fileName,
    Value<int?> sizeBytes = const Value.absent(),
    Value<int?> modifiedMs = const Value.absent(),
    String? title,
    String? artist,
    String? album,
    String? titleKey,
    String? artistKey,
    String? albumKey,
    Value<int?> durationMs = const Value.absent(),
    Value<String?> container = const Value.absent(),
    Value<String?> codec = const Value.absent(),
    String? metadataState,
    int? normalizationVersion,
    int? revision,
    int? isPresent,
    Value<int?> bitrateKbps = const Value.absent(),
    Value<int?> sampleRateHz = const Value.absent(),
    Value<int?> channels = const Value.absent(),
    Value<int?> isLossless = const Value.absent(),
    String? qualityReadState,
  }) => LocalTrack(
    id: id ?? this.id,
    platform: platform ?? this.platform,
    locationKey: locationKey ?? this.locationKey,
    locator: locator ?? this.locator,
    fileName: fileName ?? this.fileName,
    sizeBytes: sizeBytes.present ? sizeBytes.value : this.sizeBytes,
    modifiedMs: modifiedMs.present ? modifiedMs.value : this.modifiedMs,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    titleKey: titleKey ?? this.titleKey,
    artistKey: artistKey ?? this.artistKey,
    albumKey: albumKey ?? this.albumKey,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    container: container.present ? container.value : this.container,
    codec: codec.present ? codec.value : this.codec,
    metadataState: metadataState ?? this.metadataState,
    normalizationVersion: normalizationVersion ?? this.normalizationVersion,
    revision: revision ?? this.revision,
    isPresent: isPresent ?? this.isPresent,
    bitrateKbps: bitrateKbps.present ? bitrateKbps.value : this.bitrateKbps,
    sampleRateHz: sampleRateHz.present ? sampleRateHz.value : this.sampleRateHz,
    channels: channels.present ? channels.value : this.channels,
    isLossless: isLossless.present ? isLossless.value : this.isLossless,
    qualityReadState: qualityReadState ?? this.qualityReadState,
  );
  LocalTrack copyWithCompanion(LocalTracksCompanion data) {
    return LocalTrack(
      id: data.id.present ? data.id.value : this.id,
      platform: data.platform.present ? data.platform.value : this.platform,
      locationKey: data.locationKey.present
          ? data.locationKey.value
          : this.locationKey,
      locator: data.locator.present ? data.locator.value : this.locator,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      modifiedMs: data.modifiedMs.present
          ? data.modifiedMs.value
          : this.modifiedMs,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      titleKey: data.titleKey.present ? data.titleKey.value : this.titleKey,
      artistKey: data.artistKey.present ? data.artistKey.value : this.artistKey,
      albumKey: data.albumKey.present ? data.albumKey.value : this.albumKey,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      container: data.container.present ? data.container.value : this.container,
      codec: data.codec.present ? data.codec.value : this.codec,
      metadataState: data.metadataState.present
          ? data.metadataState.value
          : this.metadataState,
      normalizationVersion: data.normalizationVersion.present
          ? data.normalizationVersion.value
          : this.normalizationVersion,
      revision: data.revision.present ? data.revision.value : this.revision,
      isPresent: data.isPresent.present ? data.isPresent.value : this.isPresent,
      bitrateKbps: data.bitrateKbps.present
          ? data.bitrateKbps.value
          : this.bitrateKbps,
      sampleRateHz: data.sampleRateHz.present
          ? data.sampleRateHz.value
          : this.sampleRateHz,
      channels: data.channels.present ? data.channels.value : this.channels,
      isLossless: data.isLossless.present
          ? data.isLossless.value
          : this.isLossless,
      qualityReadState: data.qualityReadState.present
          ? data.qualityReadState.value
          : this.qualityReadState,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalTrack(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('locationKey: $locationKey, ')
          ..write('locator: $locator, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('modifiedMs: $modifiedMs, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('titleKey: $titleKey, ')
          ..write('artistKey: $artistKey, ')
          ..write('albumKey: $albumKey, ')
          ..write('durationMs: $durationMs, ')
          ..write('container: $container, ')
          ..write('codec: $codec, ')
          ..write('metadataState: $metadataState, ')
          ..write('normalizationVersion: $normalizationVersion, ')
          ..write('revision: $revision, ')
          ..write('isPresent: $isPresent, ')
          ..write('bitrateKbps: $bitrateKbps, ')
          ..write('sampleRateHz: $sampleRateHz, ')
          ..write('channels: $channels, ')
          ..write('isLossless: $isLossless, ')
          ..write('qualityReadState: $qualityReadState')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    platform,
    locationKey,
    locator,
    fileName,
    sizeBytes,
    modifiedMs,
    title,
    artist,
    album,
    titleKey,
    artistKey,
    albumKey,
    durationMs,
    container,
    codec,
    metadataState,
    normalizationVersion,
    revision,
    isPresent,
    bitrateKbps,
    sampleRateHz,
    channels,
    isLossless,
    qualityReadState,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalTrack &&
          other.id == this.id &&
          other.platform == this.platform &&
          other.locationKey == this.locationKey &&
          other.locator == this.locator &&
          other.fileName == this.fileName &&
          other.sizeBytes == this.sizeBytes &&
          other.modifiedMs == this.modifiedMs &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.titleKey == this.titleKey &&
          other.artistKey == this.artistKey &&
          other.albumKey == this.albumKey &&
          other.durationMs == this.durationMs &&
          other.container == this.container &&
          other.codec == this.codec &&
          other.metadataState == this.metadataState &&
          other.normalizationVersion == this.normalizationVersion &&
          other.revision == this.revision &&
          other.isPresent == this.isPresent &&
          other.bitrateKbps == this.bitrateKbps &&
          other.sampleRateHz == this.sampleRateHz &&
          other.channels == this.channels &&
          other.isLossless == this.isLossless &&
          other.qualityReadState == this.qualityReadState);
}

class LocalTracksCompanion extends UpdateCompanion<LocalTrack> {
  final Value<int> id;
  final Value<String> platform;
  final Value<String> locationKey;
  final Value<String> locator;
  final Value<String> fileName;
  final Value<int?> sizeBytes;
  final Value<int?> modifiedMs;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<String> titleKey;
  final Value<String> artistKey;
  final Value<String> albumKey;
  final Value<int?> durationMs;
  final Value<String?> container;
  final Value<String?> codec;
  final Value<String> metadataState;
  final Value<int> normalizationVersion;
  final Value<int> revision;
  final Value<int> isPresent;
  final Value<int?> bitrateKbps;
  final Value<int?> sampleRateHz;
  final Value<int?> channels;
  final Value<int?> isLossless;
  final Value<String> qualityReadState;
  const LocalTracksCompanion({
    this.id = const Value.absent(),
    this.platform = const Value.absent(),
    this.locationKey = const Value.absent(),
    this.locator = const Value.absent(),
    this.fileName = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.modifiedMs = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.titleKey = const Value.absent(),
    this.artistKey = const Value.absent(),
    this.albumKey = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.container = const Value.absent(),
    this.codec = const Value.absent(),
    this.metadataState = const Value.absent(),
    this.normalizationVersion = const Value.absent(),
    this.revision = const Value.absent(),
    this.isPresent = const Value.absent(),
    this.bitrateKbps = const Value.absent(),
    this.sampleRateHz = const Value.absent(),
    this.channels = const Value.absent(),
    this.isLossless = const Value.absent(),
    this.qualityReadState = const Value.absent(),
  });
  LocalTracksCompanion.insert({
    this.id = const Value.absent(),
    required String platform,
    required String locationKey,
    required String locator,
    required String fileName,
    this.sizeBytes = const Value.absent(),
    this.modifiedMs = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.titleKey = const Value.absent(),
    this.artistKey = const Value.absent(),
    this.albumKey = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.container = const Value.absent(),
    this.codec = const Value.absent(),
    this.metadataState = const Value.absent(),
    this.normalizationVersion = const Value.absent(),
    this.revision = const Value.absent(),
    this.isPresent = const Value.absent(),
    this.bitrateKbps = const Value.absent(),
    this.sampleRateHz = const Value.absent(),
    this.channels = const Value.absent(),
    this.isLossless = const Value.absent(),
    this.qualityReadState = const Value.absent(),
  }) : platform = Value(platform),
       locationKey = Value(locationKey),
       locator = Value(locator),
       fileName = Value(fileName);
  static Insertable<LocalTrack> custom({
    Expression<int>? id,
    Expression<String>? platform,
    Expression<String>? locationKey,
    Expression<String>? locator,
    Expression<String>? fileName,
    Expression<int>? sizeBytes,
    Expression<int>? modifiedMs,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<String>? titleKey,
    Expression<String>? artistKey,
    Expression<String>? albumKey,
    Expression<int>? durationMs,
    Expression<String>? container,
    Expression<String>? codec,
    Expression<String>? metadataState,
    Expression<int>? normalizationVersion,
    Expression<int>? revision,
    Expression<int>? isPresent,
    Expression<int>? bitrateKbps,
    Expression<int>? sampleRateHz,
    Expression<int>? channels,
    Expression<int>? isLossless,
    Expression<String>? qualityReadState,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (platform != null) 'platform': platform,
      if (locationKey != null) 'location_key': locationKey,
      if (locator != null) 'locator': locator,
      if (fileName != null) 'file_name': fileName,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (modifiedMs != null) 'modified_ms': modifiedMs,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (titleKey != null) 'title_key': titleKey,
      if (artistKey != null) 'artist_key': artistKey,
      if (albumKey != null) 'album_key': albumKey,
      if (durationMs != null) 'duration_ms': durationMs,
      if (container != null) 'container': container,
      if (codec != null) 'codec': codec,
      if (metadataState != null) 'metadata_state': metadataState,
      if (normalizationVersion != null)
        'normalization_version': normalizationVersion,
      if (revision != null) 'revision': revision,
      if (isPresent != null) 'is_present': isPresent,
      if (bitrateKbps != null) 'bitrate_kbps': bitrateKbps,
      if (sampleRateHz != null) 'sample_rate_hz': sampleRateHz,
      if (channels != null) 'channels': channels,
      if (isLossless != null) 'is_lossless': isLossless,
      if (qualityReadState != null) 'quality_read_state': qualityReadState,
    });
  }

  LocalTracksCompanion copyWith({
    Value<int>? id,
    Value<String>? platform,
    Value<String>? locationKey,
    Value<String>? locator,
    Value<String>? fileName,
    Value<int?>? sizeBytes,
    Value<int?>? modifiedMs,
    Value<String>? title,
    Value<String>? artist,
    Value<String>? album,
    Value<String>? titleKey,
    Value<String>? artistKey,
    Value<String>? albumKey,
    Value<int?>? durationMs,
    Value<String?>? container,
    Value<String?>? codec,
    Value<String>? metadataState,
    Value<int>? normalizationVersion,
    Value<int>? revision,
    Value<int>? isPresent,
    Value<int?>? bitrateKbps,
    Value<int?>? sampleRateHz,
    Value<int?>? channels,
    Value<int?>? isLossless,
    Value<String>? qualityReadState,
  }) {
    return LocalTracksCompanion(
      id: id ?? this.id,
      platform: platform ?? this.platform,
      locationKey: locationKey ?? this.locationKey,
      locator: locator ?? this.locator,
      fileName: fileName ?? this.fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedMs: modifiedMs ?? this.modifiedMs,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      titleKey: titleKey ?? this.titleKey,
      artistKey: artistKey ?? this.artistKey,
      albumKey: albumKey ?? this.albumKey,
      durationMs: durationMs ?? this.durationMs,
      container: container ?? this.container,
      codec: codec ?? this.codec,
      metadataState: metadataState ?? this.metadataState,
      normalizationVersion: normalizationVersion ?? this.normalizationVersion,
      revision: revision ?? this.revision,
      isPresent: isPresent ?? this.isPresent,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      channels: channels ?? this.channels,
      isLossless: isLossless ?? this.isLossless,
      qualityReadState: qualityReadState ?? this.qualityReadState,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (locationKey.present) {
      map['location_key'] = Variable<String>(locationKey.value);
    }
    if (locator.present) {
      map['locator'] = Variable<String>(locator.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (modifiedMs.present) {
      map['modified_ms'] = Variable<int>(modifiedMs.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (titleKey.present) {
      map['title_key'] = Variable<String>(titleKey.value);
    }
    if (artistKey.present) {
      map['artist_key'] = Variable<String>(artistKey.value);
    }
    if (albumKey.present) {
      map['album_key'] = Variable<String>(albumKey.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (container.present) {
      map['container'] = Variable<String>(container.value);
    }
    if (codec.present) {
      map['codec'] = Variable<String>(codec.value);
    }
    if (metadataState.present) {
      map['metadata_state'] = Variable<String>(metadataState.value);
    }
    if (normalizationVersion.present) {
      map['normalization_version'] = Variable<int>(normalizationVersion.value);
    }
    if (revision.present) {
      map['revision'] = Variable<int>(revision.value);
    }
    if (isPresent.present) {
      map['is_present'] = Variable<int>(isPresent.value);
    }
    if (bitrateKbps.present) {
      map['bitrate_kbps'] = Variable<int>(bitrateKbps.value);
    }
    if (sampleRateHz.present) {
      map['sample_rate_hz'] = Variable<int>(sampleRateHz.value);
    }
    if (channels.present) {
      map['channels'] = Variable<int>(channels.value);
    }
    if (isLossless.present) {
      map['is_lossless'] = Variable<int>(isLossless.value);
    }
    if (qualityReadState.present) {
      map['quality_read_state'] = Variable<String>(qualityReadState.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalTracksCompanion(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('locationKey: $locationKey, ')
          ..write('locator: $locator, ')
          ..write('fileName: $fileName, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('modifiedMs: $modifiedMs, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('titleKey: $titleKey, ')
          ..write('artistKey: $artistKey, ')
          ..write('albumKey: $albumKey, ')
          ..write('durationMs: $durationMs, ')
          ..write('container: $container, ')
          ..write('codec: $codec, ')
          ..write('metadataState: $metadataState, ')
          ..write('normalizationVersion: $normalizationVersion, ')
          ..write('revision: $revision, ')
          ..write('isPresent: $isPresent, ')
          ..write('bitrateKbps: $bitrateKbps, ')
          ..write('sampleRateHz: $sampleRateHz, ')
          ..write('channels: $channels, ')
          ..write('isLossless: $isLossless, ')
          ..write('qualityReadState: $qualityReadState')
          ..write(')'))
        .toString();
  }
}

class RootFiles extends Table with TableInfo<RootFiles, RootFile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  RootFiles(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  late final GeneratedColumn<int> rootId = GeneratedColumn<int>(
    'root_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL REFERENCES library_roots(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _fileIdMeta = const VerificationMeta('fileId');
  late final GeneratedColumn<int> fileId = GeneratedColumn<int>(
    'file_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL REFERENCES local_tracks(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _seenGenerationMeta = const VerificationMeta(
    'seenGeneration',
  );
  late final GeneratedColumn<int> seenGeneration = GeneratedColumn<int>(
    'seen_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _fileLocatorMeta = const VerificationMeta(
    'fileLocator',
  );
  late final GeneratedColumn<String> fileLocator = GeneratedColumn<String>(
    'file_locator',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(file_locator) > 0)',
  );
  @override
  List<GeneratedColumn> get $columns => [
    rootId,
    fileId,
    seenGeneration,
    fileLocator,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'root_files';
  @override
  VerificationContext validateIntegrity(
    Insertable<RootFile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rootIdMeta);
    }
    if (data.containsKey('file_id')) {
      context.handle(
        _fileIdMeta,
        fileId.isAcceptableOrUnknown(data['file_id']!, _fileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_fileIdMeta);
    }
    if (data.containsKey('seen_generation')) {
      context.handle(
        _seenGenerationMeta,
        seenGeneration.isAcceptableOrUnknown(
          data['seen_generation']!,
          _seenGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_seenGenerationMeta);
    }
    if (data.containsKey('file_locator')) {
      context.handle(
        _fileLocatorMeta,
        fileLocator.isAcceptableOrUnknown(
          data['file_locator']!,
          _fileLocatorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fileLocatorMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rootId, fileId};
  @override
  RootFile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RootFile(
      rootId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}root_id'],
      )!,
      fileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_id'],
      )!,
      seenGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_generation'],
      )!,
      fileLocator: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_locator'],
      )!,
    );
  }

  @override
  RootFiles createAlias(String alias) {
    return RootFiles(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
  @override
  List<String> get customConstraints => const ['PRIMARY KEY(root_id, file_id)'];
  @override
  bool get dontWriteConstraints => true;
}

class RootFile extends DataClass implements Insertable<RootFile> {
  final int rootId;
  final int fileId;
  final int seenGeneration;
  final String fileLocator;
  const RootFile({
    required this.rootId,
    required this.fileId,
    required this.seenGeneration,
    required this.fileLocator,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['root_id'] = Variable<int>(rootId);
    map['file_id'] = Variable<int>(fileId);
    map['seen_generation'] = Variable<int>(seenGeneration);
    map['file_locator'] = Variable<String>(fileLocator);
    return map;
  }

  RootFilesCompanion toCompanion(bool nullToAbsent) {
    return RootFilesCompanion(
      rootId: Value(rootId),
      fileId: Value(fileId),
      seenGeneration: Value(seenGeneration),
      fileLocator: Value(fileLocator),
    );
  }

  factory RootFile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RootFile(
      rootId: serializer.fromJson<int>(json['root_id']),
      fileId: serializer.fromJson<int>(json['file_id']),
      seenGeneration: serializer.fromJson<int>(json['seen_generation']),
      fileLocator: serializer.fromJson<String>(json['file_locator']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'root_id': serializer.toJson<int>(rootId),
      'file_id': serializer.toJson<int>(fileId),
      'seen_generation': serializer.toJson<int>(seenGeneration),
      'file_locator': serializer.toJson<String>(fileLocator),
    };
  }

  RootFile copyWith({
    int? rootId,
    int? fileId,
    int? seenGeneration,
    String? fileLocator,
  }) => RootFile(
    rootId: rootId ?? this.rootId,
    fileId: fileId ?? this.fileId,
    seenGeneration: seenGeneration ?? this.seenGeneration,
    fileLocator: fileLocator ?? this.fileLocator,
  );
  RootFile copyWithCompanion(RootFilesCompanion data) {
    return RootFile(
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      fileId: data.fileId.present ? data.fileId.value : this.fileId,
      seenGeneration: data.seenGeneration.present
          ? data.seenGeneration.value
          : this.seenGeneration,
      fileLocator: data.fileLocator.present
          ? data.fileLocator.value
          : this.fileLocator,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RootFile(')
          ..write('rootId: $rootId, ')
          ..write('fileId: $fileId, ')
          ..write('seenGeneration: $seenGeneration, ')
          ..write('fileLocator: $fileLocator')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(rootId, fileId, seenGeneration, fileLocator);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RootFile &&
          other.rootId == this.rootId &&
          other.fileId == this.fileId &&
          other.seenGeneration == this.seenGeneration &&
          other.fileLocator == this.fileLocator);
}

class RootFilesCompanion extends UpdateCompanion<RootFile> {
  final Value<int> rootId;
  final Value<int> fileId;
  final Value<int> seenGeneration;
  final Value<String> fileLocator;
  const RootFilesCompanion({
    this.rootId = const Value.absent(),
    this.fileId = const Value.absent(),
    this.seenGeneration = const Value.absent(),
    this.fileLocator = const Value.absent(),
  });
  RootFilesCompanion.insert({
    required int rootId,
    required int fileId,
    required int seenGeneration,
    required String fileLocator,
  }) : rootId = Value(rootId),
       fileId = Value(fileId),
       seenGeneration = Value(seenGeneration),
       fileLocator = Value(fileLocator);
  static Insertable<RootFile> custom({
    Expression<int>? rootId,
    Expression<int>? fileId,
    Expression<int>? seenGeneration,
    Expression<String>? fileLocator,
  }) {
    return RawValuesInsertable({
      if (rootId != null) 'root_id': rootId,
      if (fileId != null) 'file_id': fileId,
      if (seenGeneration != null) 'seen_generation': seenGeneration,
      if (fileLocator != null) 'file_locator': fileLocator,
    });
  }

  RootFilesCompanion copyWith({
    Value<int>? rootId,
    Value<int>? fileId,
    Value<int>? seenGeneration,
    Value<String>? fileLocator,
  }) {
    return RootFilesCompanion(
      rootId: rootId ?? this.rootId,
      fileId: fileId ?? this.fileId,
      seenGeneration: seenGeneration ?? this.seenGeneration,
      fileLocator: fileLocator ?? this.fileLocator,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rootId.present) {
      map['root_id'] = Variable<int>(rootId.value);
    }
    if (fileId.present) {
      map['file_id'] = Variable<int>(fileId.value);
    }
    if (seenGeneration.present) {
      map['seen_generation'] = Variable<int>(seenGeneration.value);
    }
    if (fileLocator.present) {
      map['file_locator'] = Variable<String>(fileLocator.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RootFilesCompanion(')
          ..write('rootId: $rootId, ')
          ..write('fileId: $fileId, ')
          ..write('seenGeneration: $seenGeneration, ')
          ..write('fileLocator: $fileLocator')
          ..write(')'))
        .toString();
  }
}

class SourceTrackLinks extends Table
    with TableInfo<SourceTrackLinks, SourceTrackLink> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  SourceTrackLinks(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(source) > 0)',
  );
  static const VerificationMeta _sourceTrackIdMeta = const VerificationMeta(
    'sourceTrackId',
  );
  late final GeneratedColumn<String> sourceTrackId = GeneratedColumn<String>(
    'source_track_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(source_track_id) > 0)',
  );
  static const VerificationMeta _fileIdMeta = const VerificationMeta('fileId');
  late final GeneratedColumn<int> fileId = GeneratedColumn<int>(
    'file_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL REFERENCES local_tracks(id)ON DELETE RESTRICT',
  );
  static const VerificationMeta _fileRevisionMeta = const VerificationMeta(
    'fileRevision',
  );
  late final GeneratedColumn<int> fileRevision = GeneratedColumn<int>(
    'file_revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _decisionMeta = const VerificationMeta(
    'decision',
  );
  late final GeneratedColumn<String> decision = GeneratedColumn<String>(
    'decision',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (decision IN (\'manual\', \'automatic\'))',
  );
  static const VerificationMeta _matcherVersionMeta = const VerificationMeta(
    'matcherVersion',
  );
  late final GeneratedColumn<int> matcherVersion = GeneratedColumn<int>(
    'matcher_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (matcher_version > 0)',
  );
  static const VerificationMeta _confirmedMsMeta = const VerificationMeta(
    'confirmedMs',
  );
  late final GeneratedColumn<int> confirmedMs = GeneratedColumn<int>(
    'confirmed_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    sourceTrackId,
    fileId,
    fileRevision,
    decision,
    matcherVersion,
    confirmedMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_track_links';
  @override
  VerificationContext validateIntegrity(
    Insertable<SourceTrackLink> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('source_track_id')) {
      context.handle(
        _sourceTrackIdMeta,
        sourceTrackId.isAcceptableOrUnknown(
          data['source_track_id']!,
          _sourceTrackIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceTrackIdMeta);
    }
    if (data.containsKey('file_id')) {
      context.handle(
        _fileIdMeta,
        fileId.isAcceptableOrUnknown(data['file_id']!, _fileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_fileIdMeta);
    }
    if (data.containsKey('file_revision')) {
      context.handle(
        _fileRevisionMeta,
        fileRevision.isAcceptableOrUnknown(
          data['file_revision']!,
          _fileRevisionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fileRevisionMeta);
    }
    if (data.containsKey('decision')) {
      context.handle(
        _decisionMeta,
        decision.isAcceptableOrUnknown(data['decision']!, _decisionMeta),
      );
    } else if (isInserting) {
      context.missing(_decisionMeta);
    }
    if (data.containsKey('matcher_version')) {
      context.handle(
        _matcherVersionMeta,
        matcherVersion.isAcceptableOrUnknown(
          data['matcher_version']!,
          _matcherVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_matcherVersionMeta);
    }
    if (data.containsKey('confirmed_ms')) {
      context.handle(
        _confirmedMsMeta,
        confirmedMs.isAcceptableOrUnknown(
          data['confirmed_ms']!,
          _confirmedMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_confirmedMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, sourceTrackId};
  @override
  SourceTrackLink map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SourceTrackLink(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceTrackId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_track_id'],
      )!,
      fileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_id'],
      )!,
      fileRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_revision'],
      )!,
      decision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}decision'],
      )!,
      matcherVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}matcher_version'],
      )!,
      confirmedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}confirmed_ms'],
      )!,
    );
  }

  @override
  SourceTrackLinks createAlias(String alias) {
    return SourceTrackLinks(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, source_track_id)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class SourceTrackLink extends DataClass implements Insertable<SourceTrackLink> {
  final String source;
  final String sourceTrackId;
  final int fileId;
  final int fileRevision;
  final String decision;
  final int matcherVersion;
  final int confirmedMs;
  const SourceTrackLink({
    required this.source,
    required this.sourceTrackId,
    required this.fileId,
    required this.fileRevision,
    required this.decision,
    required this.matcherVersion,
    required this.confirmedMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['source_track_id'] = Variable<String>(sourceTrackId);
    map['file_id'] = Variable<int>(fileId);
    map['file_revision'] = Variable<int>(fileRevision);
    map['decision'] = Variable<String>(decision);
    map['matcher_version'] = Variable<int>(matcherVersion);
    map['confirmed_ms'] = Variable<int>(confirmedMs);
    return map;
  }

  SourceTrackLinksCompanion toCompanion(bool nullToAbsent) {
    return SourceTrackLinksCompanion(
      source: Value(source),
      sourceTrackId: Value(sourceTrackId),
      fileId: Value(fileId),
      fileRevision: Value(fileRevision),
      decision: Value(decision),
      matcherVersion: Value(matcherVersion),
      confirmedMs: Value(confirmedMs),
    );
  }

  factory SourceTrackLink.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SourceTrackLink(
      source: serializer.fromJson<String>(json['source']),
      sourceTrackId: serializer.fromJson<String>(json['source_track_id']),
      fileId: serializer.fromJson<int>(json['file_id']),
      fileRevision: serializer.fromJson<int>(json['file_revision']),
      decision: serializer.fromJson<String>(json['decision']),
      matcherVersion: serializer.fromJson<int>(json['matcher_version']),
      confirmedMs: serializer.fromJson<int>(json['confirmed_ms']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'source_track_id': serializer.toJson<String>(sourceTrackId),
      'file_id': serializer.toJson<int>(fileId),
      'file_revision': serializer.toJson<int>(fileRevision),
      'decision': serializer.toJson<String>(decision),
      'matcher_version': serializer.toJson<int>(matcherVersion),
      'confirmed_ms': serializer.toJson<int>(confirmedMs),
    };
  }

  SourceTrackLink copyWith({
    String? source,
    String? sourceTrackId,
    int? fileId,
    int? fileRevision,
    String? decision,
    int? matcherVersion,
    int? confirmedMs,
  }) => SourceTrackLink(
    source: source ?? this.source,
    sourceTrackId: sourceTrackId ?? this.sourceTrackId,
    fileId: fileId ?? this.fileId,
    fileRevision: fileRevision ?? this.fileRevision,
    decision: decision ?? this.decision,
    matcherVersion: matcherVersion ?? this.matcherVersion,
    confirmedMs: confirmedMs ?? this.confirmedMs,
  );
  SourceTrackLink copyWithCompanion(SourceTrackLinksCompanion data) {
    return SourceTrackLink(
      source: data.source.present ? data.source.value : this.source,
      sourceTrackId: data.sourceTrackId.present
          ? data.sourceTrackId.value
          : this.sourceTrackId,
      fileId: data.fileId.present ? data.fileId.value : this.fileId,
      fileRevision: data.fileRevision.present
          ? data.fileRevision.value
          : this.fileRevision,
      decision: data.decision.present ? data.decision.value : this.decision,
      matcherVersion: data.matcherVersion.present
          ? data.matcherVersion.value
          : this.matcherVersion,
      confirmedMs: data.confirmedMs.present
          ? data.confirmedMs.value
          : this.confirmedMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SourceTrackLink(')
          ..write('source: $source, ')
          ..write('sourceTrackId: $sourceTrackId, ')
          ..write('fileId: $fileId, ')
          ..write('fileRevision: $fileRevision, ')
          ..write('decision: $decision, ')
          ..write('matcherVersion: $matcherVersion, ')
          ..write('confirmedMs: $confirmedMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    source,
    sourceTrackId,
    fileId,
    fileRevision,
    decision,
    matcherVersion,
    confirmedMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceTrackLink &&
          other.source == this.source &&
          other.sourceTrackId == this.sourceTrackId &&
          other.fileId == this.fileId &&
          other.fileRevision == this.fileRevision &&
          other.decision == this.decision &&
          other.matcherVersion == this.matcherVersion &&
          other.confirmedMs == this.confirmedMs);
}

class SourceTrackLinksCompanion extends UpdateCompanion<SourceTrackLink> {
  final Value<String> source;
  final Value<String> sourceTrackId;
  final Value<int> fileId;
  final Value<int> fileRevision;
  final Value<String> decision;
  final Value<int> matcherVersion;
  final Value<int> confirmedMs;
  const SourceTrackLinksCompanion({
    this.source = const Value.absent(),
    this.sourceTrackId = const Value.absent(),
    this.fileId = const Value.absent(),
    this.fileRevision = const Value.absent(),
    this.decision = const Value.absent(),
    this.matcherVersion = const Value.absent(),
    this.confirmedMs = const Value.absent(),
  });
  SourceTrackLinksCompanion.insert({
    required String source,
    required String sourceTrackId,
    required int fileId,
    required int fileRevision,
    required String decision,
    required int matcherVersion,
    required int confirmedMs,
  }) : source = Value(source),
       sourceTrackId = Value(sourceTrackId),
       fileId = Value(fileId),
       fileRevision = Value(fileRevision),
       decision = Value(decision),
       matcherVersion = Value(matcherVersion),
       confirmedMs = Value(confirmedMs);
  static Insertable<SourceTrackLink> custom({
    Expression<String>? source,
    Expression<String>? sourceTrackId,
    Expression<int>? fileId,
    Expression<int>? fileRevision,
    Expression<String>? decision,
    Expression<int>? matcherVersion,
    Expression<int>? confirmedMs,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (sourceTrackId != null) 'source_track_id': sourceTrackId,
      if (fileId != null) 'file_id': fileId,
      if (fileRevision != null) 'file_revision': fileRevision,
      if (decision != null) 'decision': decision,
      if (matcherVersion != null) 'matcher_version': matcherVersion,
      if (confirmedMs != null) 'confirmed_ms': confirmedMs,
    });
  }

  SourceTrackLinksCompanion copyWith({
    Value<String>? source,
    Value<String>? sourceTrackId,
    Value<int>? fileId,
    Value<int>? fileRevision,
    Value<String>? decision,
    Value<int>? matcherVersion,
    Value<int>? confirmedMs,
  }) {
    return SourceTrackLinksCompanion(
      source: source ?? this.source,
      sourceTrackId: sourceTrackId ?? this.sourceTrackId,
      fileId: fileId ?? this.fileId,
      fileRevision: fileRevision ?? this.fileRevision,
      decision: decision ?? this.decision,
      matcherVersion: matcherVersion ?? this.matcherVersion,
      confirmedMs: confirmedMs ?? this.confirmedMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceTrackId.present) {
      map['source_track_id'] = Variable<String>(sourceTrackId.value);
    }
    if (fileId.present) {
      map['file_id'] = Variable<int>(fileId.value);
    }
    if (fileRevision.present) {
      map['file_revision'] = Variable<int>(fileRevision.value);
    }
    if (decision.present) {
      map['decision'] = Variable<String>(decision.value);
    }
    if (matcherVersion.present) {
      map['matcher_version'] = Variable<int>(matcherVersion.value);
    }
    if (confirmedMs.present) {
      map['confirmed_ms'] = Variable<int>(confirmedMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceTrackLinksCompanion(')
          ..write('source: $source, ')
          ..write('sourceTrackId: $sourceTrackId, ')
          ..write('fileId: $fileId, ')
          ..write('fileRevision: $fileRevision, ')
          ..write('decision: $decision, ')
          ..write('matcherVersion: $matcherVersion, ')
          ..write('confirmedMs: $confirmedMs')
          ..write(')'))
        .toString();
  }
}

class PlaybackSettings extends Table
    with TableInfo<PlaybackSettings, PlaybackSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  PlaybackSettings(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL PRIMARY KEY CHECK (id = 1)',
  );
  static const VerificationMeta _localQualityModeMeta = const VerificationMeta(
    'localQualityMode',
  );
  late final GeneratedColumn<String> localQualityMode = GeneratedColumn<String>(
    'local_quality_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'followOnline\' CHECK (local_quality_mode IN (\'followOnline\', \'highestLocal\'))',
    defaultValue: const CustomExpression('\'followOnline\''),
  );
  @override
  List<GeneratedColumn> get $columns => [id, localQualityMode];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playback_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaybackSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('local_quality_mode')) {
      context.handle(
        _localQualityModeMeta,
        localQualityMode.isAcceptableOrUnknown(
          data['local_quality_mode']!,
          _localQualityModeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybackSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybackSetting(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      localQualityMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_quality_mode'],
      )!,
    );
  }

  @override
  PlaybackSettings createAlias(String alias) {
    return PlaybackSettings(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class PlaybackSetting extends DataClass implements Insertable<PlaybackSetting> {
  final int id;
  final String localQualityMode;
  const PlaybackSetting({required this.id, required this.localQualityMode});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['local_quality_mode'] = Variable<String>(localQualityMode);
    return map;
  }

  PlaybackSettingsCompanion toCompanion(bool nullToAbsent) {
    return PlaybackSettingsCompanion(
      id: Value(id),
      localQualityMode: Value(localQualityMode),
    );
  }

  factory PlaybackSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaybackSetting(
      id: serializer.fromJson<int>(json['id']),
      localQualityMode: serializer.fromJson<String>(json['local_quality_mode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'local_quality_mode': serializer.toJson<String>(localQualityMode),
    };
  }

  PlaybackSetting copyWith({int? id, String? localQualityMode}) =>
      PlaybackSetting(
        id: id ?? this.id,
        localQualityMode: localQualityMode ?? this.localQualityMode,
      );
  PlaybackSetting copyWithCompanion(PlaybackSettingsCompanion data) {
    return PlaybackSetting(
      id: data.id.present ? data.id.value : this.id,
      localQualityMode: data.localQualityMode.present
          ? data.localQualityMode.value
          : this.localQualityMode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaybackSetting(')
          ..write('id: $id, ')
          ..write('localQualityMode: $localQualityMode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, localQualityMode);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackSetting &&
          other.id == this.id &&
          other.localQualityMode == this.localQualityMode);
}

class PlaybackSettingsCompanion extends UpdateCompanion<PlaybackSetting> {
  final Value<int> id;
  final Value<String> localQualityMode;
  const PlaybackSettingsCompanion({
    this.id = const Value.absent(),
    this.localQualityMode = const Value.absent(),
  });
  PlaybackSettingsCompanion.insert({
    this.id = const Value.absent(),
    this.localQualityMode = const Value.absent(),
  });
  static Insertable<PlaybackSetting> custom({
    Expression<int>? id,
    Expression<String>? localQualityMode,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localQualityMode != null) 'local_quality_mode': localQualityMode,
    });
  }

  PlaybackSettingsCompanion copyWith({
    Value<int>? id,
    Value<String>? localQualityMode,
  }) {
    return PlaybackSettingsCompanion(
      id: id ?? this.id,
      localQualityMode: localQualityMode ?? this.localQualityMode,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (localQualityMode.present) {
      map['local_quality_mode'] = Variable<String>(localQualityMode.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaybackSettingsCompanion(')
          ..write('id: $id, ')
          ..write('localQualityMode: $localQualityMode')
          ..write(')'))
        .toString();
  }
}

abstract class _$LibraryDatabase extends GeneratedDatabase {
  _$LibraryDatabase(QueryExecutor e) : super(e);
  $LibraryDatabaseManager get managers => $LibraryDatabaseManager(this);
  late final LibraryRoots libraryRoots = LibraryRoots(this);
  late final LocalTracks localTracks = LocalTracks(this);
  late final RootFiles rootFiles = RootFiles(this);
  late final Index rootFilesByFile = Index(
    'root_files_by_file',
    'CREATE INDEX root_files_by_file ON root_files (file_id, root_id)',
  );
  late final Index tracksMatchTitleDuration = Index(
    'tracks_match_title_duration',
    'CREATE INDEX tracks_match_title_duration ON local_tracks (normalization_version, title_key, duration_ms, id) WHERE is_present = 1 AND metadata_state = \'ready\' AND title_key <> \'\'',
  );
  late final Index tracksPresentPage = Index(
    'tracks_present_page',
    'CREATE INDEX tracks_present_page ON local_tracks (id) WHERE is_present = 1',
  );
  late final SourceTrackLinks sourceTrackLinks = SourceTrackLinks(this);
  late final Index sourceLinksByFile = Index(
    'source_links_by_file',
    'CREATE INDEX source_links_by_file ON source_track_links (file_id)',
  );
  late final PlaybackSettings playbackSettings = PlaybackSettings(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    libraryRoots,
    localTracks,
    rootFiles,
    rootFilesByFile,
    tracksMatchTitleDuration,
    tracksPresentPage,
    sourceTrackLinks,
    sourceLinksByFile,
    playbackSettings,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_roots',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('root_files', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_tracks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('root_files', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $LibraryRootsCreateCompanionBuilder = LibraryRootsCompanion Function({
  Value<int> id,
  required String platform,
  required String locationKey,
  required String locator,
  required String displayName,
  Value<int> isAccessible,
  Value<int> scanGeneration,
  Value<int?> activeGeneration,
  Value<String> lastScanState,
  Value<int?> lastCompletedMs,
});
typedef $LibraryRootsUpdateCompanionBuilder = LibraryRootsCompanion Function({
  Value<int> id,
  Value<String> platform,
  Value<String> locationKey,
  Value<String> locator,
  Value<String> displayName,
  Value<int> isAccessible,
  Value<int> scanGeneration,
  Value<int?> activeGeneration,
  Value<String> lastScanState,
  Value<int?> lastCompletedMs,
});

final class $LibraryRootsReferences
    extends BaseReferences<_$LibraryDatabase, LibraryRoots, LibraryRoot> {
  $LibraryRootsReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<RootFiles, List<RootFile>> _rootFilesRefsTable(
    _$LibraryDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.rootFiles,
    aliasName: 'library_roots__id__root_files__root_id',
  );

  $RootFilesProcessedTableManager get rootFilesRefs {
    final manager = $RootFilesTableManager(
      $_db,
      $_db.rootFiles,
    ).filter((f) => f.rootId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_rootFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $LibraryRootsFilterComposer
    extends Composer<_$LibraryDatabase, LibraryRoots> {
  $LibraryRootsFilterComposer({
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

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locator => $composableBuilder(
    column: $table.locator,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isAccessible => $composableBuilder(
    column: $table.isAccessible,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scanGeneration => $composableBuilder(
    column: $table.scanGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get activeGeneration => $composableBuilder(
    column: $table.activeGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastScanState => $composableBuilder(
    column: $table.lastScanState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastCompletedMs => $composableBuilder(
    column: $table.lastCompletedMs,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> rootFilesRefs(
    Expression<bool> Function($RootFilesFilterComposer f) f,
  ) {
    final $RootFilesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.rootFiles,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $RootFilesFilterComposer(
            $db: $db,
            $table: $db.rootFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $LibraryRootsOrderingComposer
    extends Composer<_$LibraryDatabase, LibraryRoots> {
  $LibraryRootsOrderingComposer({
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

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locator => $composableBuilder(
    column: $table.locator,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isAccessible => $composableBuilder(
    column: $table.isAccessible,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scanGeneration => $composableBuilder(
    column: $table.scanGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get activeGeneration => $composableBuilder(
    column: $table.activeGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastScanState => $composableBuilder(
    column: $table.lastScanState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastCompletedMs => $composableBuilder(
    column: $table.lastCompletedMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $LibraryRootsAnnotationComposer
    extends Composer<_$LibraryDatabase, LibraryRoots> {
  $LibraryRootsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locator =>
      $composableBuilder(column: $table.locator, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get isAccessible => $composableBuilder(
    column: $table.isAccessible,
    builder: (column) => column,
  );

  GeneratedColumn<int> get scanGeneration => $composableBuilder(
    column: $table.scanGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get activeGeneration => $composableBuilder(
    column: $table.activeGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastScanState => $composableBuilder(
    column: $table.lastScanState,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastCompletedMs => $composableBuilder(
    column: $table.lastCompletedMs,
    builder: (column) => column,
  );

  Expression<T> rootFilesRefs<T extends Object>(
    Expression<T> Function($RootFilesAnnotationComposer a) f,
  ) {
    final $RootFilesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.rootFiles,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $RootFilesAnnotationComposer(
            $db: $db,
            $table: $db.rootFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $LibraryRootsTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          LibraryRoots,
          LibraryRoot,
          $LibraryRootsFilterComposer,
          $LibraryRootsOrderingComposer,
          $LibraryRootsAnnotationComposer,
          $LibraryRootsCreateCompanionBuilder,
          $LibraryRootsUpdateCompanionBuilder,
          (LibraryRoot, $LibraryRootsReferences),
          LibraryRoot,
          PrefetchHooks Function({bool rootFilesRefs})
        > {
  $LibraryRootsTableManager(_$LibraryDatabase db, LibraryRoots table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $LibraryRootsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $LibraryRootsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $LibraryRootsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<String> locationKey = const Value.absent(),
                Value<String> locator = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<int> isAccessible = const Value.absent(),
                Value<int> scanGeneration = const Value.absent(),
                Value<int?> activeGeneration = const Value.absent(),
                Value<String> lastScanState = const Value.absent(),
                Value<int?> lastCompletedMs = const Value.absent(),
              }) => LibraryRootsCompanion(
                id: id,
                platform: platform,
                locationKey: locationKey,
                locator: locator,
                displayName: displayName,
                isAccessible: isAccessible,
                scanGeneration: scanGeneration,
                activeGeneration: activeGeneration,
                lastScanState: lastScanState,
                lastCompletedMs: lastCompletedMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String platform,
                required String locationKey,
                required String locator,
                required String displayName,
                Value<int> isAccessible = const Value.absent(),
                Value<int> scanGeneration = const Value.absent(),
                Value<int?> activeGeneration = const Value.absent(),
                Value<String> lastScanState = const Value.absent(),
                Value<int?> lastCompletedMs = const Value.absent(),
              }) => LibraryRootsCompanion.insert(
                id: id,
                platform: platform,
                locationKey: locationKey,
                locator: locator,
                displayName: displayName,
                isAccessible: isAccessible,
                scanGeneration: scanGeneration,
                activeGeneration: activeGeneration,
                lastScanState: lastScanState,
                lastCompletedMs: lastCompletedMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<LibraryRoots, LibraryRoot>(table),
                  $LibraryRootsReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({rootFilesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (rootFilesRefs) db.rootFiles],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (rootFilesRefs)
                    await $_getPrefetchedDataByColumns<
                      LibraryRoot,
                      LibraryRoots,
                      RootFile,
                      RootFiles
                    >(
                      currentTable: table,
                      referencedTable: $LibraryRootsReferences
                          ._rootFilesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $LibraryRootsReferences(db, table, p0).rootFilesRefs,
                      currentColumn: 'id',
                      referencedColumn: 'root_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $LibraryRootsProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      LibraryRoots,
      LibraryRoot,
      $LibraryRootsFilterComposer,
      $LibraryRootsOrderingComposer,
      $LibraryRootsAnnotationComposer,
      $LibraryRootsCreateCompanionBuilder,
      $LibraryRootsUpdateCompanionBuilder,
      (LibraryRoot, $LibraryRootsReferences),
      LibraryRoot,
      PrefetchHooks Function({bool rootFilesRefs})
    >;
typedef $LocalTracksCreateCompanionBuilder = LocalTracksCompanion Function({
  Value<int> id,
  required String platform,
  required String locationKey,
  required String locator,
  required String fileName,
  Value<int?> sizeBytes,
  Value<int?> modifiedMs,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String> titleKey,
  Value<String> artistKey,
  Value<String> albumKey,
  Value<int?> durationMs,
  Value<String?> container,
  Value<String?> codec,
  Value<String> metadataState,
  Value<int> normalizationVersion,
  Value<int> revision,
  Value<int> isPresent,
  Value<int?> bitrateKbps,
  Value<int?> sampleRateHz,
  Value<int?> channels,
  Value<int?> isLossless,
  Value<String> qualityReadState,
});
typedef $LocalTracksUpdateCompanionBuilder = LocalTracksCompanion Function({
  Value<int> id,
  Value<String> platform,
  Value<String> locationKey,
  Value<String> locator,
  Value<String> fileName,
  Value<int?> sizeBytes,
  Value<int?> modifiedMs,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String> titleKey,
  Value<String> artistKey,
  Value<String> albumKey,
  Value<int?> durationMs,
  Value<String?> container,
  Value<String?> codec,
  Value<String> metadataState,
  Value<int> normalizationVersion,
  Value<int> revision,
  Value<int> isPresent,
  Value<int?> bitrateKbps,
  Value<int?> sampleRateHz,
  Value<int?> channels,
  Value<int?> isLossless,
  Value<String> qualityReadState,
});

final class $LocalTracksReferences
    extends BaseReferences<_$LibraryDatabase, LocalTracks, LocalTrack> {
  $LocalTracksReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<RootFiles, List<RootFile>> _rootFilesRefsTable(
    _$LibraryDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.rootFiles,
    aliasName: 'local_tracks__id__root_files__file_id',
  );

  $RootFilesProcessedTableManager get rootFilesRefs {
    final manager = $RootFilesTableManager(
      $_db,
      $_db.rootFiles,
    ).filter((f) => f.fileId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_rootFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<SourceTrackLinks, List<SourceTrackLink>>
  _sourceTrackLinksRefsTable(_$LibraryDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.sourceTrackLinks,
        aliasName: 'local_tracks__id__source_track_links__file_id',
      );

  $SourceTrackLinksProcessedTableManager get sourceTrackLinksRefs {
    final manager = $SourceTrackLinksTableManager(
      $_db,
      $_db.sourceTrackLinks,
    ).filter((f) => f.fileId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _sourceTrackLinksRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $LocalTracksFilterComposer
    extends Composer<_$LibraryDatabase, LocalTracks> {
  $LocalTracksFilterComposer({
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

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locator => $composableBuilder(
    column: $table.locator,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modifiedMs => $composableBuilder(
    column: $table.modifiedMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get album => $composableBuilder(
    column: $table.album,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get titleKey => $composableBuilder(
    column: $table.titleKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artistKey => $composableBuilder(
    column: $table.artistKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get albumKey => $composableBuilder(
    column: $table.albumKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get codec => $composableBuilder(
    column: $table.codec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get normalizationVersion => $composableBuilder(
    column: $table.normalizationVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isPresent => $composableBuilder(
    column: $table.isPresent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bitrateKbps => $composableBuilder(
    column: $table.bitrateKbps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sampleRateHz => $composableBuilder(
    column: $table.sampleRateHz,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get channels => $composableBuilder(
    column: $table.channels,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isLossless => $composableBuilder(
    column: $table.isLossless,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get qualityReadState => $composableBuilder(
    column: $table.qualityReadState,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> rootFilesRefs(
    Expression<bool> Function($RootFilesFilterComposer f) f,
  ) {
    final $RootFilesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.rootFiles,
      getReferencedColumn: (t) => t.fileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $RootFilesFilterComposer(
            $db: $db,
            $table: $db.rootFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> sourceTrackLinksRefs(
    Expression<bool> Function($SourceTrackLinksFilterComposer f) f,
  ) {
    final $SourceTrackLinksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceTrackLinks,
      getReferencedColumn: (t) => t.fileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $SourceTrackLinksFilterComposer(
            $db: $db,
            $table: $db.sourceTrackLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $LocalTracksOrderingComposer
    extends Composer<_$LibraryDatabase, LocalTracks> {
  $LocalTracksOrderingComposer({
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

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locator => $composableBuilder(
    column: $table.locator,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modifiedMs => $composableBuilder(
    column: $table.modifiedMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get album => $composableBuilder(
    column: $table.album,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get titleKey => $composableBuilder(
    column: $table.titleKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artistKey => $composableBuilder(
    column: $table.artistKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get albumKey => $composableBuilder(
    column: $table.albumKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get codec => $composableBuilder(
    column: $table.codec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get normalizationVersion => $composableBuilder(
    column: $table.normalizationVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isPresent => $composableBuilder(
    column: $table.isPresent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bitrateKbps => $composableBuilder(
    column: $table.bitrateKbps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sampleRateHz => $composableBuilder(
    column: $table.sampleRateHz,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get channels => $composableBuilder(
    column: $table.channels,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isLossless => $composableBuilder(
    column: $table.isLossless,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get qualityReadState => $composableBuilder(
    column: $table.qualityReadState,
    builder: (column) => ColumnOrderings(column),
  );
}

class $LocalTracksAnnotationComposer
    extends Composer<_$LibraryDatabase, LocalTracks> {
  $LocalTracksAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<String> get locationKey => $composableBuilder(
    column: $table.locationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locator =>
      $composableBuilder(column: $table.locator, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<int> get modifiedMs => $composableBuilder(
    column: $table.modifiedMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<String> get titleKey =>
      $composableBuilder(column: $table.titleKey, builder: (column) => column);

  GeneratedColumn<String> get artistKey =>
      $composableBuilder(column: $table.artistKey, builder: (column) => column);

  GeneratedColumn<String> get albumKey =>
      $composableBuilder(column: $table.albumKey, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get container =>
      $composableBuilder(column: $table.container, builder: (column) => column);

  GeneratedColumn<String> get codec =>
      $composableBuilder(column: $table.codec, builder: (column) => column);

  GeneratedColumn<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => column,
  );

  GeneratedColumn<int> get normalizationVersion => $composableBuilder(
    column: $table.normalizationVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);

  GeneratedColumn<int> get isPresent =>
      $composableBuilder(column: $table.isPresent, builder: (column) => column);

  GeneratedColumn<int> get bitrateKbps => $composableBuilder(
    column: $table.bitrateKbps,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sampleRateHz => $composableBuilder(
    column: $table.sampleRateHz,
    builder: (column) => column,
  );

  GeneratedColumn<int> get channels =>
      $composableBuilder(column: $table.channels, builder: (column) => column);

  GeneratedColumn<int> get isLossless => $composableBuilder(
    column: $table.isLossless,
    builder: (column) => column,
  );

  GeneratedColumn<String> get qualityReadState => $composableBuilder(
    column: $table.qualityReadState,
    builder: (column) => column,
  );

  Expression<T> rootFilesRefs<T extends Object>(
    Expression<T> Function($RootFilesAnnotationComposer a) f,
  ) {
    final $RootFilesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.rootFiles,
      getReferencedColumn: (t) => t.fileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $RootFilesAnnotationComposer(
            $db: $db,
            $table: $db.rootFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> sourceTrackLinksRefs<T extends Object>(
    Expression<T> Function($SourceTrackLinksAnnotationComposer a) f,
  ) {
    final $SourceTrackLinksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sourceTrackLinks,
      getReferencedColumn: (t) => t.fileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $SourceTrackLinksAnnotationComposer(
            $db: $db,
            $table: $db.sourceTrackLinks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $LocalTracksTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          LocalTracks,
          LocalTrack,
          $LocalTracksFilterComposer,
          $LocalTracksOrderingComposer,
          $LocalTracksAnnotationComposer,
          $LocalTracksCreateCompanionBuilder,
          $LocalTracksUpdateCompanionBuilder,
          (LocalTrack, $LocalTracksReferences),
          LocalTrack,
          PrefetchHooks Function({
            bool rootFilesRefs,
            bool sourceTrackLinksRefs,
          })
        > {
  $LocalTracksTableManager(_$LibraryDatabase db, LocalTracks table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $LocalTracksFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $LocalTracksOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $LocalTracksAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<String> locationKey = const Value.absent(),
                Value<String> locator = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<int?> modifiedMs = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> artist = const Value.absent(),
                Value<String> album = const Value.absent(),
                Value<String> titleKey = const Value.absent(),
                Value<String> artistKey = const Value.absent(),
                Value<String> albumKey = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> container = const Value.absent(),
                Value<String?> codec = const Value.absent(),
                Value<String> metadataState = const Value.absent(),
                Value<int> normalizationVersion = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<int> isPresent = const Value.absent(),
                Value<int?> bitrateKbps = const Value.absent(),
                Value<int?> sampleRateHz = const Value.absent(),
                Value<int?> channels = const Value.absent(),
                Value<int?> isLossless = const Value.absent(),
                Value<String> qualityReadState = const Value.absent(),
              }) => LocalTracksCompanion(
                id: id,
                platform: platform,
                locationKey: locationKey,
                locator: locator,
                fileName: fileName,
                sizeBytes: sizeBytes,
                modifiedMs: modifiedMs,
                title: title,
                artist: artist,
                album: album,
                titleKey: titleKey,
                artistKey: artistKey,
                albumKey: albumKey,
                durationMs: durationMs,
                container: container,
                codec: codec,
                metadataState: metadataState,
                normalizationVersion: normalizationVersion,
                revision: revision,
                isPresent: isPresent,
                bitrateKbps: bitrateKbps,
                sampleRateHz: sampleRateHz,
                channels: channels,
                isLossless: isLossless,
                qualityReadState: qualityReadState,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String platform,
                required String locationKey,
                required String locator,
                required String fileName,
                Value<int?> sizeBytes = const Value.absent(),
                Value<int?> modifiedMs = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> artist = const Value.absent(),
                Value<String> album = const Value.absent(),
                Value<String> titleKey = const Value.absent(),
                Value<String> artistKey = const Value.absent(),
                Value<String> albumKey = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> container = const Value.absent(),
                Value<String?> codec = const Value.absent(),
                Value<String> metadataState = const Value.absent(),
                Value<int> normalizationVersion = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<int> isPresent = const Value.absent(),
                Value<int?> bitrateKbps = const Value.absent(),
                Value<int?> sampleRateHz = const Value.absent(),
                Value<int?> channels = const Value.absent(),
                Value<int?> isLossless = const Value.absent(),
                Value<String> qualityReadState = const Value.absent(),
              }) => LocalTracksCompanion.insert(
                id: id,
                platform: platform,
                locationKey: locationKey,
                locator: locator,
                fileName: fileName,
                sizeBytes: sizeBytes,
                modifiedMs: modifiedMs,
                title: title,
                artist: artist,
                album: album,
                titleKey: titleKey,
                artistKey: artistKey,
                albumKey: albumKey,
                durationMs: durationMs,
                container: container,
                codec: codec,
                metadataState: metadataState,
                normalizationVersion: normalizationVersion,
                revision: revision,
                isPresent: isPresent,
                bitrateKbps: bitrateKbps,
                sampleRateHz: sampleRateHz,
                channels: channels,
                isLossless: isLossless,
                qualityReadState: qualityReadState,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<LocalTracks, LocalTrack>(table),
                  $LocalTracksReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({rootFilesRefs = false, sourceTrackLinksRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (rootFilesRefs) db.rootFiles,
                    if (sourceTrackLinksRefs) db.sourceTrackLinks,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (rootFilesRefs)
                        await $_getPrefetchedDataByColumns<
                          LocalTrack,
                          LocalTracks,
                          RootFile,
                          RootFiles
                        >(
                          currentTable: table,
                          referencedTable: $LocalTracksReferences
                              ._rootFilesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $LocalTracksReferences(
                                db,
                                table,
                                p0,
                              ).rootFilesRefs,
                          currentColumn: 'id',
                          referencedColumn: 'file_id',
                          typedResults: items,
                        ),
                      if (sourceTrackLinksRefs)
                        await $_getPrefetchedDataByColumns<
                          LocalTrack,
                          LocalTracks,
                          SourceTrackLink,
                          SourceTrackLinks
                        >(
                          currentTable: table,
                          referencedTable: $LocalTracksReferences
                              ._sourceTrackLinksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $LocalTracksReferences(
                                db,
                                table,
                                p0,
                              ).sourceTrackLinksRefs,
                          currentColumn: 'id',
                          referencedColumn: 'file_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $LocalTracksProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      LocalTracks,
      LocalTrack,
      $LocalTracksFilterComposer,
      $LocalTracksOrderingComposer,
      $LocalTracksAnnotationComposer,
      $LocalTracksCreateCompanionBuilder,
      $LocalTracksUpdateCompanionBuilder,
      (LocalTrack, $LocalTracksReferences),
      LocalTrack,
      PrefetchHooks Function({bool rootFilesRefs, bool sourceTrackLinksRefs})
    >;
typedef $RootFilesCreateCompanionBuilder = RootFilesCompanion Function({
  required int rootId,
  required int fileId,
  required int seenGeneration,
  required String fileLocator,
});
typedef $RootFilesUpdateCompanionBuilder = RootFilesCompanion Function({
  Value<int> rootId,
  Value<int> fileId,
  Value<int> seenGeneration,
  Value<String> fileLocator,
});

final class $RootFilesReferences
    extends BaseReferences<_$LibraryDatabase, RootFiles, RootFile> {
  $RootFilesReferences(super.$_db, super.$_table, super.$_typedResult);

  static LibraryRoots _rootIdTable(_$LibraryDatabase db) =>
      db.libraryRoots.createAlias('root_files__root_id__library_roots__id');

  $LibraryRootsProcessedTableManager get rootId {
    final $_column = $_itemColumn<int>('root_id')!;

    final manager = $LibraryRootsTableManager(
      $_db,
      $_db.libraryRoots,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_rootIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static LocalTracks _fileIdTable(_$LibraryDatabase db) =>
      db.localTracks.createAlias('root_files__file_id__local_tracks__id');

  $LocalTracksProcessedTableManager get fileId {
    final $_column = $_itemColumn<int>('file_id')!;

    final manager = $LocalTracksTableManager(
      $_db,
      $_db.localTracks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_fileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $RootFilesFilterComposer extends Composer<_$LibraryDatabase, RootFiles> {
  $RootFilesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get seenGeneration => $composableBuilder(
    column: $table.seenGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileLocator => $composableBuilder(
    column: $table.fileLocator,
    builder: (column) => ColumnFilters(column),
  );

  $LibraryRootsFilterComposer get rootId {
    final $LibraryRootsFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.libraryRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LibraryRootsFilterComposer(
            $db: $db,
            $table: $db.libraryRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $LocalTracksFilterComposer get fileId {
    final $LocalTracksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksFilterComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $RootFilesOrderingComposer
    extends Composer<_$LibraryDatabase, RootFiles> {
  $RootFilesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get seenGeneration => $composableBuilder(
    column: $table.seenGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileLocator => $composableBuilder(
    column: $table.fileLocator,
    builder: (column) => ColumnOrderings(column),
  );

  $LibraryRootsOrderingComposer get rootId {
    final $LibraryRootsOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.libraryRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LibraryRootsOrderingComposer(
            $db: $db,
            $table: $db.libraryRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $LocalTracksOrderingComposer get fileId {
    final $LocalTracksOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksOrderingComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $RootFilesAnnotationComposer
    extends Composer<_$LibraryDatabase, RootFiles> {
  $RootFilesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get seenGeneration => $composableBuilder(
    column: $table.seenGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileLocator => $composableBuilder(
    column: $table.fileLocator,
    builder: (column) => column,
  );

  $LibraryRootsAnnotationComposer get rootId {
    final $LibraryRootsAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.libraryRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LibraryRootsAnnotationComposer(
            $db: $db,
            $table: $db.libraryRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $LocalTracksAnnotationComposer get fileId {
    final $LocalTracksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksAnnotationComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $RootFilesTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          RootFiles,
          RootFile,
          $RootFilesFilterComposer,
          $RootFilesOrderingComposer,
          $RootFilesAnnotationComposer,
          $RootFilesCreateCompanionBuilder,
          $RootFilesUpdateCompanionBuilder,
          (RootFile, $RootFilesReferences),
          RootFile,
          PrefetchHooks Function({bool rootId, bool fileId})
        > {
  $RootFilesTableManager(_$LibraryDatabase db, RootFiles table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $RootFilesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $RootFilesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $RootFilesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rootId = const Value.absent(),
                Value<int> fileId = const Value.absent(),
                Value<int> seenGeneration = const Value.absent(),
                Value<String> fileLocator = const Value.absent(),
              }) => RootFilesCompanion(
                rootId: rootId,
                fileId: fileId,
                seenGeneration: seenGeneration,
                fileLocator: fileLocator,
              ),
          createCompanionCallback:
              ({
                required int rootId,
                required int fileId,
                required int seenGeneration,
                required String fileLocator,
              }) => RootFilesCompanion.insert(
                rootId: rootId,
                fileId: fileId,
                seenGeneration: seenGeneration,
                fileLocator: fileLocator,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<RootFiles, RootFile>(table),
                  $RootFilesReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({rootId = false, fileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (rootId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.rootId,
                        referencedTable: $RootFilesReferences._rootIdTable(db),
                        referencedColumn: $RootFilesReferences
                            ._rootIdTable(db)
                            .id,
                      ) as T;
                    }
                    if (fileId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.fileId,
                        referencedTable: $RootFilesReferences._fileIdTable(db),
                        referencedColumn: $RootFilesReferences
                            ._fileIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $RootFilesProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      RootFiles,
      RootFile,
      $RootFilesFilterComposer,
      $RootFilesOrderingComposer,
      $RootFilesAnnotationComposer,
      $RootFilesCreateCompanionBuilder,
      $RootFilesUpdateCompanionBuilder,
      (RootFile, $RootFilesReferences),
      RootFile,
      PrefetchHooks Function({bool rootId, bool fileId})
    >;
typedef $SourceTrackLinksCreateCompanionBuilder =
    SourceTrackLinksCompanion Function({
      required String source,
      required String sourceTrackId,
      required int fileId,
      required int fileRevision,
      required String decision,
      required int matcherVersion,
      required int confirmedMs,
    });
typedef $SourceTrackLinksUpdateCompanionBuilder =
    SourceTrackLinksCompanion Function({
      Value<String> source,
      Value<String> sourceTrackId,
      Value<int> fileId,
      Value<int> fileRevision,
      Value<String> decision,
      Value<int> matcherVersion,
      Value<int> confirmedMs,
    });

final class $SourceTrackLinksReferences
    extends
        BaseReferences<_$LibraryDatabase, SourceTrackLinks, SourceTrackLink> {
  $SourceTrackLinksReferences(super.$_db, super.$_table, super.$_typedResult);

  static LocalTracks _fileIdTable(_$LibraryDatabase db) => db.localTracks
      .createAlias('source_track_links__file_id__local_tracks__id');

  $LocalTracksProcessedTableManager get fileId {
    final $_column = $_itemColumn<int>('file_id')!;

    final manager = $LocalTracksTableManager(
      $_db,
      $_db.localTracks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_fileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $SourceTrackLinksFilterComposer
    extends Composer<_$LibraryDatabase, SourceTrackLinks> {
  $SourceTrackLinksFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceTrackId => $composableBuilder(
    column: $table.sourceTrackId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileRevision => $composableBuilder(
    column: $table.fileRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get decision => $composableBuilder(
    column: $table.decision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get matcherVersion => $composableBuilder(
    column: $table.matcherVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get confirmedMs => $composableBuilder(
    column: $table.confirmedMs,
    builder: (column) => ColumnFilters(column),
  );

  $LocalTracksFilterComposer get fileId {
    final $LocalTracksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksFilterComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $SourceTrackLinksOrderingComposer
    extends Composer<_$LibraryDatabase, SourceTrackLinks> {
  $SourceTrackLinksOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceTrackId => $composableBuilder(
    column: $table.sourceTrackId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileRevision => $composableBuilder(
    column: $table.fileRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get decision => $composableBuilder(
    column: $table.decision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get matcherVersion => $composableBuilder(
    column: $table.matcherVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get confirmedMs => $composableBuilder(
    column: $table.confirmedMs,
    builder: (column) => ColumnOrderings(column),
  );

  $LocalTracksOrderingComposer get fileId {
    final $LocalTracksOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksOrderingComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $SourceTrackLinksAnnotationComposer
    extends Composer<_$LibraryDatabase, SourceTrackLinks> {
  $SourceTrackLinksAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceTrackId => $composableBuilder(
    column: $table.sourceTrackId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get fileRevision => $composableBuilder(
    column: $table.fileRevision,
    builder: (column) => column,
  );

  GeneratedColumn<String> get decision =>
      $composableBuilder(column: $table.decision, builder: (column) => column);

  GeneratedColumn<int> get matcherVersion => $composableBuilder(
    column: $table.matcherVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get confirmedMs => $composableBuilder(
    column: $table.confirmedMs,
    builder: (column) => column,
  );

  $LocalTracksAnnotationComposer get fileId {
    final $LocalTracksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.fileId,
      referencedTable: $db.localTracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $LocalTracksAnnotationComposer(
            $db: $db,
            $table: $db.localTracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $SourceTrackLinksTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          SourceTrackLinks,
          SourceTrackLink,
          $SourceTrackLinksFilterComposer,
          $SourceTrackLinksOrderingComposer,
          $SourceTrackLinksAnnotationComposer,
          $SourceTrackLinksCreateCompanionBuilder,
          $SourceTrackLinksUpdateCompanionBuilder,
          (SourceTrackLink, $SourceTrackLinksReferences),
          SourceTrackLink,
          PrefetchHooks Function({bool fileId})
        > {
  $SourceTrackLinksTableManager(_$LibraryDatabase db, SourceTrackLinks table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $SourceTrackLinksFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $SourceTrackLinksOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $SourceTrackLinksAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> sourceTrackId = const Value.absent(),
                Value<int> fileId = const Value.absent(),
                Value<int> fileRevision = const Value.absent(),
                Value<String> decision = const Value.absent(),
                Value<int> matcherVersion = const Value.absent(),
                Value<int> confirmedMs = const Value.absent(),
              }) => SourceTrackLinksCompanion(
                source: source,
                sourceTrackId: sourceTrackId,
                fileId: fileId,
                fileRevision: fileRevision,
                decision: decision,
                matcherVersion: matcherVersion,
                confirmedMs: confirmedMs,
              ),
          createCompanionCallback:
              ({
                required String source,
                required String sourceTrackId,
                required int fileId,
                required int fileRevision,
                required String decision,
                required int matcherVersion,
                required int confirmedMs,
              }) => SourceTrackLinksCompanion.insert(
                source: source,
                sourceTrackId: sourceTrackId,
                fileId: fileId,
                fileRevision: fileRevision,
                decision: decision,
                matcherVersion: matcherVersion,
                confirmedMs: confirmedMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<SourceTrackLinks, SourceTrackLink>(table),
                  $SourceTrackLinksReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({fileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (fileId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.fileId,
                        referencedTable: $SourceTrackLinksReferences
                            ._fileIdTable(db),
                        referencedColumn: $SourceTrackLinksReferences
                            ._fileIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $SourceTrackLinksProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      SourceTrackLinks,
      SourceTrackLink,
      $SourceTrackLinksFilterComposer,
      $SourceTrackLinksOrderingComposer,
      $SourceTrackLinksAnnotationComposer,
      $SourceTrackLinksCreateCompanionBuilder,
      $SourceTrackLinksUpdateCompanionBuilder,
      (SourceTrackLink, $SourceTrackLinksReferences),
      SourceTrackLink,
      PrefetchHooks Function({bool fileId})
    >;
typedef $PlaybackSettingsCreateCompanionBuilder =
    PlaybackSettingsCompanion Function({
      Value<int> id,
      Value<String> localQualityMode,
    });
typedef $PlaybackSettingsUpdateCompanionBuilder =
    PlaybackSettingsCompanion Function({
      Value<int> id,
      Value<String> localQualityMode,
    });

class $PlaybackSettingsFilterComposer
    extends Composer<_$LibraryDatabase, PlaybackSettings> {
  $PlaybackSettingsFilterComposer({
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

  ColumnFilters<String> get localQualityMode => $composableBuilder(
    column: $table.localQualityMode,
    builder: (column) => ColumnFilters(column),
  );
}

class $PlaybackSettingsOrderingComposer
    extends Composer<_$LibraryDatabase, PlaybackSettings> {
  $PlaybackSettingsOrderingComposer({
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

  ColumnOrderings<String> get localQualityMode => $composableBuilder(
    column: $table.localQualityMode,
    builder: (column) => ColumnOrderings(column),
  );
}

class $PlaybackSettingsAnnotationComposer
    extends Composer<_$LibraryDatabase, PlaybackSettings> {
  $PlaybackSettingsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get localQualityMode => $composableBuilder(
    column: $table.localQualityMode,
    builder: (column) => column,
  );
}

class $PlaybackSettingsTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          PlaybackSettings,
          PlaybackSetting,
          $PlaybackSettingsFilterComposer,
          $PlaybackSettingsOrderingComposer,
          $PlaybackSettingsAnnotationComposer,
          $PlaybackSettingsCreateCompanionBuilder,
          $PlaybackSettingsUpdateCompanionBuilder,
          (
            PlaybackSetting,
            BaseReferences<
              _$LibraryDatabase,
              PlaybackSettings,
              PlaybackSetting
            >,
          ),
          PlaybackSetting,
          PrefetchHooks Function()
        > {
  $PlaybackSettingsTableManager(_$LibraryDatabase db, PlaybackSettings table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $PlaybackSettingsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $PlaybackSettingsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $PlaybackSettingsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> localQualityMode = const Value.absent(),
              }) => PlaybackSettingsCompanion(
                id: id,
                localQualityMode: localQualityMode,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> localQualityMode = const Value.absent(),
              }) => PlaybackSettingsCompanion.insert(
                id: id,
                localQualityMode: localQualityMode,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<PlaybackSettings, PlaybackSetting>(table),
                  BaseReferences<
                    _$LibraryDatabase,
                    PlaybackSettings,
                    PlaybackSetting
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $PlaybackSettingsProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      PlaybackSettings,
      PlaybackSetting,
      $PlaybackSettingsFilterComposer,
      $PlaybackSettingsOrderingComposer,
      $PlaybackSettingsAnnotationComposer,
      $PlaybackSettingsCreateCompanionBuilder,
      $PlaybackSettingsUpdateCompanionBuilder,
      (
        PlaybackSetting,
        BaseReferences<_$LibraryDatabase, PlaybackSettings, PlaybackSetting>,
      ),
      PlaybackSetting,
      PrefetchHooks Function()
    >;

class $LibraryDatabaseManager {
  final _$LibraryDatabase _db;
  $LibraryDatabaseManager(this._db);
  $LibraryRootsTableManager get libraryRoots =>
      $LibraryRootsTableManager(_db, _db.libraryRoots);
  $LocalTracksTableManager get localTracks =>
      $LocalTracksTableManager(_db, _db.localTracks);
  $RootFilesTableManager get rootFiles =>
      $RootFilesTableManager(_db, _db.rootFiles);
  $SourceTrackLinksTableManager get sourceTrackLinks =>
      $SourceTrackLinksTableManager(_db, _db.sourceTrackLinks);
  $PlaybackSettingsTableManager get playbackSettings =>
      $PlaybackSettingsTableManager(_db, _db.playbackSettings);
}
