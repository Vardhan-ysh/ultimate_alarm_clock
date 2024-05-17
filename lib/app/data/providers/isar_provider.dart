import 'dart:async';

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultimate_alarm_clock/app/data/models/alarm_model.dart';
import 'package:ultimate_alarm_clock/app/data/models/ringtone_model.dart';
import 'package:ultimate_alarm_clock/app/data/models/timer_model.dart';
import 'package:ultimate_alarm_clock/app/utils/utils.dart';
import 'package:sqflite/sqflite.dart';

class IsarDb {
  static final IsarDb _instance = IsarDb._internal();
  late Future<Isar> db;

  factory IsarDb() {
    return _instance;
  }

  IsarDb._internal() {
    db = openDB();
  }

  Future<Database?> getAlarmSQLiteDatabase() async {
    Database? db;

    final dir = await getDatabasesPath();
    final dbPath = '$dir/alarms.db';
    db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
    return db;
  }

  Future<Database?> getTimerSQLiteDatabase() async {
    Database? db;
    final dir = await getDatabasesPath();
    db = await openDatabase(
      '$dir/timer.db',
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          create table timers ( 
            id integer primary key autoincrement, 
            timerTime text not null,
            mainTimerTime text not null,
            intervalToAlarm integer not null,
            ringtoneName text not null,
            timerName text not null,
            isPaused integer not null)
        ''');
      },
    );
    return db;
  }

  void _onCreate(Database db, int version) async {
    // Create tables for alarms and ringtones (modify column types as needed)
    await db.execute('''
      CREATE TABLE alarms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        firestoreId TEXT,
        alarmTime TEXT NOT NULL,
        alarmID TEXT NOT NULL UNIQUE,
        isEnabled INTEGER NOT NULL DEFAULT 1,
        isLocationEnabled INTEGER NOT NULL DEFAULT 0,
        isSharedAlarmEnabled INTEGER NOT NULL DEFAULT 0,
        isWeatherEnabled INTEGER NOT NULL DEFAULT 0,
        location TEXT,
        activityInterval INTEGER,
        minutesSinceMidnight INTEGER NOT NULL,
        days TEXT NOT NULL,
        weatherTypes TEXT NOT NULL,
        isMathsEnabled INTEGER NOT NULL DEFAULT 0,
        mathsDifficulty INTEGER,
        numMathsQuestions INTEGER,
        isShakeEnabled INTEGER NOT NULL DEFAULT 0,
        shakeTimes INTEGER,
        isQrEnabled INTEGER NOT NULL DEFAULT 0,
        qrValue TEXT,
        isPedometerEnabled INTEGER NOT NULL DEFAULT 0,
        numberOfSteps INTEGER,
        intervalToAlarm INTEGER,
        isActivityEnabled INTEGER NOT NULL DEFAULT 0,
        sharedUserIds TEXT,
        ownerId TEXT NOT NULL,
        ownerName TEXT NOT NULL,
        lastEditedUserId TEXT,
        mutexLock INTEGER NOT NULL DEFAULT 0,
        mainAlarmTime TEXT,
        label TEXT,
        isOneTime INTEGER NOT NULL DEFAULT 0,
        snoozeDuration INTEGER,
        gradient INTEGER,
        ringtoneName TEXT,
        note TEXT,
        deleteAfterGoesOff INTEGER NOT NULL DEFAULT 0,
        showMotivationalQuote INTEGER NOT NULL DEFAULT 0,
        volMin REAL,
        volMax REAL
      )
    ''');
    await db.execute('''
      CREATE TABLE ringtones (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ringtoneName TEXT NOT NULL,
        ringtonePath TEXT NOT NULL,
        currentCounterOfUsage INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<Isar> openDB() async {
    final dir = await getApplicationDocumentsDirectory();
    if (Isar.instanceNames.isEmpty) {
      return await Isar.open(
        [AlarmModelSchema, RingtoneModelSchema, TimerModelSchema],
        directory: dir.path,
        inspector: true,
      );
    }
    return Future.value(Isar.getInstance());
  }

  static Future<AlarmModel> addAlarm(AlarmModel alarmRecord) async {
    final isarProvider = IsarDb();
    final sql = await IsarDb().getAlarmSQLiteDatabase();
    final db = await isarProvider.db;
    await db.writeTxn(() async {
      await db.alarmModels.put(alarmRecord);
    });
    final sqlmap = alarmRecord.toSQFliteMap();
    await sql!.insert('alarms', sqlmap).then((value) {
      sql.close();
    });
    return alarmRecord;
  }

  static Future<AlarmModel> getTriggeredAlarm(String time) async {
    final isarProvider = IsarDb();
    final db = await isarProvider.db;

    final alarms = await db.alarmModels
        .where()
        .filter()
        .isEnabledEqualTo(true)
        .and()
        .alarmTimeEqualTo(time)
        .findAll();
    return alarms.first;
  }

  static Future<bool> doesAlarmExist(String alarmID) async {
    final isarProvider = IsarDb();
    final db = await isarProvider.db;
    final alarms =
        await db.alarmModels.where().filter().alarmIDEqualTo(alarmID).findAll();

    return alarms.isNotEmpty;
  }

  static Future<AlarmModel> getLatestAlarm(
    AlarmModel alarmRecord,
    bool wantNextAlarm,
  ) async {
    int nowInMinutes = 0;
    final isarProvider = IsarDb();
    final db = await isarProvider.db;

// Increasing a day since we need alarms AFTER the current time
// Logically, alarms at current time will ring in the future ;-;
    if (wantNextAlarm == true) {
      nowInMinutes = Utils.timeOfDayToInt(
        TimeOfDay(
          hour: TimeOfDay.now().hour,
          minute: TimeOfDay.now().minute + 1,
        ),
      );
    } else {
      nowInMinutes = Utils.timeOfDayToInt(
        TimeOfDay(
          hour: TimeOfDay.now().hour,
          minute: TimeOfDay.now().minute,
        ),
      );
    }

    // Get all enabled alarms
    List<AlarmModel> alarms =
        await db.alarmModels.where().filter().isEnabledEqualTo(true).findAll();

    if (alarms.isEmpty) {
      alarmRecord.minutesSinceMidnight = -1;
      return alarmRecord;
    } else {
      // Get the closest alarm to the current time
      AlarmModel closestAlarm = alarms.reduce((a, b) {
        int aTimeUntilNextAlarm = a.minutesSinceMidnight - nowInMinutes;
        int bTimeUntilNextAlarm = b.minutesSinceMidnight - nowInMinutes;

        // Check if alarm repeats on any day
        bool aRepeats = a.days.any((day) => day);
        bool bRepeats = b.days.any((day) => day);

        // If alarm is one-time and has already passed or is happening now,
        // set time until next alarm to next day
        if (!aRepeats && aTimeUntilNextAlarm < 0) {
          aTimeUntilNextAlarm += Duration.minutesPerDay;
        }
        if (!bRepeats && bTimeUntilNextAlarm < 0) {
          bTimeUntilNextAlarm += Duration.minutesPerDay;
        }

        // If alarm repeats on any day, find the next upcoming day
        if (aRepeats) {
          int currentDay = DateTime.now().weekday - 1;
          for (int i = 0; i < a.days.length; i++) {
            int dayIndex = (currentDay + i) % a.days.length;
            if (a.days[dayIndex]) {
              aTimeUntilNextAlarm += i * Duration.minutesPerDay;
              break;
            }
          }
        }

        if (bRepeats) {
          int currentDay = DateTime.now().weekday - 1;
          for (int i = 0; i < b.days.length; i++) {
            int dayIndex = (currentDay + i) % b.days.length;
            if (b.days[dayIndex]) {
              bTimeUntilNextAlarm += i * Duration.minutesPerDay;
              break;
            }
          }
        }

        return aTimeUntilNextAlarm < bTimeUntilNextAlarm ? a : b;
      });
      return closestAlarm;
    }
  }

  static Future<void> updateAlarm(AlarmModel alarmRecord) async {
    final isarProvider = IsarDb();
    final sql = await IsarDb().getAlarmSQLiteDatabase();
    final db = await isarProvider.db;
    await db.writeTxn(() async {
      await db.alarmModels.put(alarmRecord);
    });
    await sql!.update(
      'alarms',
      alarmRecord.toSQFliteMap(),
      where: 'alarmID = ?',
      whereArgs: [alarmRecord.alarmID],
    ).then((value) {
      sql.close();
      return value;
    });
  }

  static Future<AlarmModel?> getAlarm(int id) async {
    final isarProvider = IsarDb();
    final db = await isarProvider.db;
    return db.alarmModels.get(id);
  }

  static getAlarms() async* {
    try {
      final isarProvider = IsarDb();
      final db = await isarProvider.db;
      yield* db.alarmModels.where().watch(fireImmediately: true);
    } catch (e) {
      debugPrint(e.toString());
      rethrow;
    }
  }

  static Future<void> deleteAlarm(int id) async {
    final isarProvider = IsarDb();
    final db = await isarProvider.db;
    final sql = await IsarDb().getAlarmSQLiteDatabase();
    final tobedeleted = await db.alarmModels.get(id);
    await db.writeTxn(() async {
      await db.alarmModels.delete(id);
    });
    await sql!.delete(
      'alarms',
      where: 'alarmID = ?',
      whereArgs: [tobedeleted!.alarmID],
    ).then((value) {
      sql.close();
      return value;
    });
  }

  // Timer Functions

  static Future<TimerModel> insertTimer(TimerModel timer) async {
    final isarProvider = IsarDb();
    final sql = await IsarDb().getTimerSQLiteDatabase();
    final db = await isarProvider.db;
    await db.writeTxn(() async {
      await db.timerModels.put(timer);
    });
    try {
      await sql!.insert('timers', timer.toMap()).then((value) {
        sql.close();
      });
    } catch (e) {
      print(e.toString());
    }
    return timer;
  }

  static Future<int> updateTimer(TimerModel timer) async {
    final sql = await IsarDb().getTimerSQLiteDatabase();
    return await sql!.update(
      'timers',
      timer.toMap(),
      where: 'id = ?',
      whereArgs: [timer.timerId],
    ).then((value) {
      sql.close();
      return value;
    });
  }

  static Future<int> updateTimerName(int id, String newTimerName) async {
    final sql = await IsarDb().getTimerSQLiteDatabase();
    return await sql!
        .update(
      'timers',
      {'timerName': newTimerName},
      where: 'id = ?',
      whereArgs: [id],
    )
        .then((value) {
      sql.close();
      return value;
    });
  }

  static Future<int> updateIsPaused(int id, int newIsPaused) async {
    final sql = await IsarDb().getTimerSQLiteDatabase();

    return await sql!
        .update(
      'timers',
      {'isPaused': newIsPaused},
      where: 'id = ?',
      whereArgs: [id],
    )
        .then((value) {
      sql.close();
      return value;
    });
  }

  static Future<int> deleteTimer(int id) async {
    final isarProvider = IsarDb();
    final sql = await IsarDb().getTimerSQLiteDatabase();
    final db = await isarProvider.db;
    await db.writeTxn(() async {
      await db.timerModels.delete(id);
    });
    return await sql!
        .delete('timers', where: 'id = ?', whereArgs: [id]).then((value) {
          print("$value ss");
      sql.close();
      return value;
    });
  }

  static Future<List<TimerModel>> getAllTimers() async {
    final sql = await IsarDb().getTimerSQLiteDatabase();
    List<Map<String, dynamic>> maps = await sql!.query('timers', columns: [
      'id',
      'timerTime',
      'mainTimerTime',
      'intervalToAlarm',
      'ringtoneName',
      'timerName',
      'isPaused'
    ]);
    if (maps.length > 0) {
      return maps.map((timer) => TimerModel.fromMap(timer)).toList();
    }
    return [];
  }

  static Stream<List<TimerModel>> getTimers() {
    final isarProvider = IsarDb();
    final controller = StreamController<List<TimerModel>>.broadcast();

    isarProvider.db.then((db) {
      final stream = db.timerModels.where().watch(fireImmediately: true);
      stream.listen(
            (data) => controller.add(data),
        onError: (error) => controller.addError(error),
        onDone: () => controller.close(),
      );
    }).catchError((error) {
      debugPrint(error.toString());
      controller.addError(error);
    });

    return controller.stream;
  }

  static Future<int> getNumberOfTimers() async {
    final sql = await IsarDb().getTimerSQLiteDatabase();
    List<Map<String, dynamic>> x =
        await sql!.rawQuery('SELECT COUNT (*) from timers');
    sql.close();
    int result = Sqflite.firstIntValue(x)!;
    return result;
  }

// Ringtone functions
  static Future<void> addCustomRingtone(
    RingtoneModel customRingtone,
  ) async {
    try {
      final isarProvider = IsarDb();
      final db = await isarProvider.db;
      await db.writeTxn(() async {
        await db.ringtoneModels.put(customRingtone);
      });
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  static Future<RingtoneModel?> getCustomRingtone({
    required int customRingtoneId,
  }) async {
    try {
      final isarProvider = IsarDb();
      final db = await isarProvider.db;
      final query = db.ringtoneModels
          .where()
          .filter()
          .isarIdEqualTo(customRingtoneId)
          .findFirst();

      return query;
    } catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }

  static Future<List<RingtoneModel>> getAllCustomRingtones() async {
    try {
      final isarProvider = IsarDb();
      final db = await isarProvider.db;

      final query = db.ringtoneModels.where().findAll();

      return query;
    } catch (e) {
      debugPrint(e.toString());
      return [];
    }
  }

  static Future<void> deleteCustomRingtone({
    required int ringtoneId,
  }) async {
    try {
      final isarProvider = IsarDb();
      final db = await isarProvider.db;

      await db.writeTxn(() async {
        await db.ringtoneModels.delete(ringtoneId);
      });
    } catch (e) {
      debugPrint(e.toString());
    }
  }
}
