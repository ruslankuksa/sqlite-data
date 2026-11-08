#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import Foundation
  import InlineSnapshotTesting
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing

  extension BaseCloudKitTests {
    final class SchemaChangeTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addColumnToRemindersAndRemindersLists() async throws {
        let personalList = RemindersList(id: 1, title: "Personal")
        let businessList = RemindersList(id: 2, title: "Business")
        let reminder = Reminder(id: 1, title: "Get milk", remindersListID: 1)
        try await userDatabase.userWrite { db in
          try db.seed {
            personalList
            businessList
            reminder
          }
        }

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let personalListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 1)
          )
          personalListRecord.setValue(1, forKey: "position", at: now)

          let businessListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 2)
          )
          businessListRecord.setValue(2, forKey: "position", at: now)

          let reminderRecord = try syncEngine.private.database.record(
            for: Reminder.recordID(for: 1)
          )
          reminderRecord.setValue(3, forKey: "position", at: now)

          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [personalListRecord, businessListRecord, reminderRecord]
          )
          .notify()

          try await userDatabase.userWrite { db in
            try #sql(
              """
              ALTER TABLE "remindersLists" 
              ADD COLUMN "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
              """
            )
            .execute(db)
            try #sql(
              """
              ALTER TABLE "reminders" 
              ADD COLUMN "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
              """
            )
            .execute(db)
          }

          let relaunchedSyncEngine = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables
              .filter { $0.base != Reminder.self && $0.base != RemindersList.self }
              + [
                SynchronizedTable(for: ReminderWithPosition.self),
                SynchronizedTable(for: RemindersListWithPosition.self),
              ],
            privateTables: syncEngine.privateTables
          )
          defer { _ = relaunchedSyncEngine }

          let remindersLists = try await userDatabase.read { db in
            try RemindersListWithPosition.order(by: \.id).fetchAll(db)
          }
          let reminders = try await userDatabase.read { db in
            try ReminderWithPosition.order(by: \.id).fetchAll(db)
          }

          expectNoDifference(
            remindersLists,
            [
              RemindersListWithPosition(id: 1, title: "Personal", position: 1),
              RemindersListWithPosition(id: 2, title: "Business", position: 2),
            ]
          )
          expectNoDifference(
            reminders,
            [
              ReminderWithPosition(
                id: 1,
                title: "Get milk",
                position: 3,
                remindersListID: 1
              )
            ]
          )
        }
      }

      /*
       * Test run from perspective of old device with old schema.
       * New schema saves record in cloud database.
       * Record syncs to old device with old schema.
       * Old device edits record without access to new schema.
       => All data (new+old schema) is sync'd to cloud database.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func oldSchemaUpdatesNewSchemaRecord() async throws {
        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        remindersListRecord.setValue(42, forKey: "position", at: 0)

        try await syncEngine.modifyRecords(scope: .private, saving: [remindersListRecord]).notify()

        try await userDatabase.userWrite { db in
          try #expect(RemindersList.fetchCount(db) == 1)
          try #expect(RemindersList.find(1).fetchOne(db) == RemindersList(id: 1, title: "Personal"))
          try RemindersList.find(1).update { $0.title = "My Stuff" }.execute(db)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     position: 42,                                                  │
          │     title: "My Stuff"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: syncEngine.container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  position: 42,
                  title: "My Stuff"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }

      /*
       * Old schema creates record and synchronizes to iCloud.
       * Schema is migrated to add a "NOT NULL" column.
       * New sync engine is launched.
       => Sync starts without emitting an error.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addColumn_OldRecordsSyncToNewSchema() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            remindersList
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        syncEngine.stop()

        try await userDatabase.userWrite { db in
          try #sql(
            """
            ALTER TABLE "remindersLists" 
            ADD COLUMN "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 42
            """
          )
          .execute(db)
        }

        // NB: Sync engine should start without emitting issue.
        _ = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables
            .filter { $0.base != Reminder.self && $0.base != RemindersList.self }
            + [
              SynchronizedTable(for: ReminderWithPosition.self),
              SynchronizedTable(for: RemindersListWithPosition.self),
            ],
          privateTables: syncEngine.privateTables
        )

        try await userDatabase.read { db in
          try #expect(
            RemindersListWithPosition.fetchAll(db) == [
              RemindersListWithPosition(id: 1, title: "Personal", position: 42)
            ]
          )
        }
      }

      /*
       * Old schema creates record and synchronizes to iCloud.
       * Schema is migrated to add a "NULL DEFAULT _" column.
       * New sync engine is launched.
       => Sync starts without emitting an error and default value is persisted in local database.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addNullableColumn_OldRecordsSyncToNewSchema() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            remindersList
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        syncEngine.stop()

        try await userDatabase.userWrite { db in
          try #sql(
            """
            ALTER TABLE "remindersLists" 
            ADD COLUMN "color" INTEGER DEFAULT 42
            """
          )
          .execute(db)
        }

        // NB: Sync engine should start without emitting issue.
        _ = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables
            .filter { $0.base != RemindersList.self }
          + [
            SynchronizedTable(for: RemindersListWithColor.self),
          ],
          privateTables: syncEngine.privateTables
        )

        try await userDatabase.read { db in
          try #expect(
            RemindersListWithColor.fetchAll(db) == [
              RemindersListWithColor(id: 1, title: "Personal", color: 42)
            ]
          )
        }
      }

      /*
       * Schema is migrated to add a "NULL DEFAULT _" column.
       * New sync engine is launched.
       * Old record with no 'color' value synchronized
       => Local database row created uses default for 'color'.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addNullableColumn_OldDeviceSyncsMissingColor() async throws {
        syncEngine.stop()

        try await userDatabase.userWrite { db in
          try #sql(
            """
            ALTER TABLE "remindersLists" 
            ADD COLUMN "color" INTEGER DEFAULT 42
            """
          )
          .execute(db)
        }

        // NB: Sync engine should start without emitting issue.
        let relaunchedSyncEngine = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables
            .filter { $0.base != RemindersList.self }
          + [
            SynchronizedTable(for: RemindersListWithColor.self),
          ],
          privateTables: syncEngine.privateTables
        )

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          let remindersListRecord = CKRecord(
            recordType: RemindersList.tableName,
            recordID: RemindersList.recordID(for: 1)
          )
          remindersListRecord.setValue(1, forKey: "id", at: now)
          remindersListRecord.setValue("My stuff", forKey: "title", at: now)
          try await relaunchedSyncEngine
            .modifyRecords(scope: .private, saving: [remindersListRecord])
            .notify()

          try await userDatabase.read { db in
            try #expect(
              RemindersListWithColor.fetchAll(db) == [
                RemindersListWithColor(id: 1, title: "My stuff", color: 42)
              ]
            )
          }
          assertInlineSnapshot(of: relaunchedSyncEngine.container, as: .customDump) {
            """
            MockCloudContainer(
              privateCloudDatabase: MockCloudDatabase(
                databaseScope: .private,
                storage: [
                  [0]: CKRecord(
                    recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                    recordType: "remindersLists",
                    parent: nil,
                    share: nil,
                    id: 1,
                    title: "My stuff"
                  )
                ]
              ),
              sharedCloudDatabase: MockCloudDatabase(
                databaseScope: .shared,
                storage: []
              )
            )
            """
          }
        }
      }

      /*
       * Schema is migrated to add a "NULL DEFAULT _" column.
       * New sync engine is launched.
       * New record with NULL 'color' value synchronized
       => Local database row created uses NULL for color
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addNullableColumn_NewDeviceSyncsNullColor() async throws {
        syncEngine.stop()

        try await userDatabase.userWrite { db in
          try #sql(
            """
            ALTER TABLE "remindersLists" 
            ADD COLUMN "color" INTEGER DEFAULT 42
            """
          )
          .execute(db)
        }

        // NB: Sync engine should start without emitting issue.
        let relaunchedSyncEngine = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables
            .filter { $0.base != RemindersList.self }
          + [
            SynchronizedTable(for: RemindersListWithColor.self),
          ],
          privateTables: syncEngine.privateTables
        )

        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          let remindersListRecord = CKRecord(
            recordType: RemindersList.tableName,
            recordID: RemindersList.recordID(for: 1)
          )
          remindersListRecord.setValue(1, forKey: "id", at: now)
          remindersListRecord.setValue("My stuff", forKey: "title", at: now)
          remindersListRecord.removeValue(forKey: "color", at: now)
          try await relaunchedSyncEngine
            .modifyRecords(scope: .private, saving: [remindersListRecord])
            .notify()

          try await userDatabase.read { db in
            try #expect(
              RemindersListWithColor.fetchAll(db) == [
                RemindersListWithColor(id: 1, title: "My stuff", color: nil)
              ]
            )
          }
          assertInlineSnapshot(of: relaunchedSyncEngine.container, as: .customDump) {
            """
            MockCloudContainer(
              privateCloudDatabase: MockCloudDatabase(
                databaseScope: .private,
                storage: [
                  [0]: CKRecord(
                    recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                    recordType: "remindersLists",
                    parent: nil,
                    share: nil,
                    id: 1,
                    title: "My stuff"
                  )
                ]
              ),
              sharedCloudDatabase: MockCloudDatabase(
                databaseScope: .shared,
                storage: []
              )
            )
            """
          }
        }
      }

      /*
       * Test run from perspective of old device with old schema.
       * Old schema saves record in cloud database.
       * New device with new schema saves record with extra fields.
       => All data (new+old schema) is sync'd to old device with old schema.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func newSchemaUpdatesOldSchemaRecord() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed { remindersList }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let remindersListRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        remindersListRecord.setValue("My Stuff", forKey: "title", at: 1)
        remindersListRecord.setValue(42, forKey: "position", at: 1)
        try await syncEngine.modifyRecords(scope: .private, saving: [remindersListRecord]).notify()

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db) == RemindersList(id: 1, title: "My Stuff"))
        }

        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     position: 42,                                                  │
          │     title: "My Stuff"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 1                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: syncEngine.container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  position: 42,
                  title: "My Stuff"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }

      /*
       * Test run from perspective of new device with new schema.
       * Old schema saves record in cloud database.
       => Data syncs new to new device with new schema.
       * New device updates record.
       => Data syncs new to cloud database.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func runWithNewSchema_oldSchemaSavesRecord_NewSchemaUpdatesRecord() async throws {
        syncEngine.stop()
        try syncEngine.tearDownSyncEngine()

        try await userDatabase.userWrite { db in
          try #sql(
            """
            ALTER TABLE "remindersLists"
            ADD COLUMN "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            """
          )
          .execute(db)
        }
        let newSyncEngine = try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables
            .filter { $0.base != RemindersList.self }
            + [
              SynchronizedTable(for: RemindersListWithPosition.self)
            ],
          privateTables: syncEngine.privateTables
        )
        defer { _ = newSyncEngine }

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)

        try await newSyncEngine.modifyRecords(scope: .private, saving: [remindersListRecord])
          .notify()

        try await userDatabase.read { db in
          try #expect(
            RemindersListWithPosition.find(1).fetchOne(db)
              == RemindersListWithPosition(id: 1, title: "Personal", position: 0)
          )
        }

        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     title: "Personal"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }

        try await userDatabase.userWrite { db in
          try RemindersListWithPosition.find(1).update {
            $0.title = "My Stuff"
            $0.position = 42
          }
          .execute(db)
        }
        try await newSyncEngine.processPendingRecordZoneChanges(scope: .private)

        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     position: 42,                                                  │
          │     title: "My Stuff"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: syncEngine.container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  position: 42,
                  title: "My Stuff"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addAssetToRemindersList() async throws {
        let personalList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            personalList
          }
        }

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let personalListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 1)
          )
          personalListRecord.setBytes(Array("image".utf8), forKey: "image", at: now)

          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [personalListRecord]
          )
          .notify()

          try await userDatabase.userWrite { db in
            try #sql(
              """
              ALTER TABLE "remindersLists" 
              ADD COLUMN "image" BLOB NOT NULL ON CONFLICT REPLACE DEFAULT X''
              """
            )
            .execute(db)
          }

          let relaunchedSyncEngine = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables
              .filter { $0.base != RemindersList.self }
              + [SynchronizedTable(for: RemindersListWithData.self)],
            privateTables: syncEngine.privateTables
          )
          defer { _ = relaunchedSyncEngine }

          let remindersLists = try await userDatabase.read { db in
            try RemindersListWithData.order(by: \.id).fetchAll(db)
          }

          expectNoDifference(
            remindersLists,
            [
              RemindersListWithData(id: 1, image: Data("image".utf8), title: "Personal")
            ]
          )
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func addAssetToRemindersList_Redownload() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            RemindersList(id: 2, title: "Business")
            RemindersList(id: 3, title: "Secret")
          }
        }

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let personalListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 1)
          )
          personalListRecord.setBytes(Array("personal-image".utf8), forKey: "image", at: now)
          let businessListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 2)
          )
          businessListRecord.setBytes(Array("business-image".utf8), forKey: "image", at: now)
          let secretListRecord = try syncEngine.private.database.record(
            for: RemindersList.recordID(for: 3)
          )
          secretListRecord.setBytes(Array("secret-image".utf8), forKey: "image", at: now)

          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [personalListRecord, businessListRecord, secretListRecord]
          )
          .notify()

          inMemoryDataManager.storage.withValue { $0.removeAll() }

          try await userDatabase.userWrite { db in
            try #sql(
              """
              ALTER TABLE "remindersLists" 
              ADD COLUMN "image" BLOB NOT NULL ON CONFLICT REPLACE DEFAULT X''
              """
            )
            .execute(db)
          }

          let relaunchedSyncEngine = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables
              .filter { $0.base != RemindersList.self }
              + [SynchronizedTable(for: RemindersListWithData.self)],
            privateTables: syncEngine.privateTables
          )
          defer { _ = relaunchedSyncEngine }

          let remindersLists = try await userDatabase.read { db in
            try RemindersListWithData.order(by: \.id).fetchAll(db)
          }

          expectNoDifference(
            remindersLists,
            [
              RemindersListWithData(id: 1, image: Data("personal-image".utf8), title: "Personal"),
              RemindersListWithData(id: 2, image: Data("business-image".utf8), title: "Business"),
              RemindersListWithData(id: 3, image: Data("secret-image".utf8), title: "Secret"),
            ]
          )
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func newTable() async throws {
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let imageRecord = CKRecord(
            recordType: "images",
            recordID: Image.recordID(for: 1)
          )
          imageRecord.setValue(1, forKey: "id", at: now)
          imageRecord.setValue("A good image", forKey: "caption", at: now)
          imageRecord.setValue(Data("image".utf8), forKey: "image", at: now)

          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [imageRecord]
          )
          .notify()
          syncEngine.stop()

          inMemoryDataManager.storage.withValue { $0.removeAll() }

          try await userDatabase.userWrite { db in
            try #sql(
              """
              CREATE TABLE "images" (
                "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                "caption" TEXT NOT NULL,
                "image" BLOB NOT NULL
              )
              """
            )
            .execute(db)
          }

          let relaunchedSyncEngine = try await SyncEngine(
            container: syncEngine.container,
            userDatabase: syncEngine.userDatabase,
            tables: syncEngine.tables + [SynchronizedTable(for: Image.self)],
            privateTables: syncEngine.privateTables
          )
          defer { _ = relaunchedSyncEngine }

          try await userDatabase.read { db in
            expectNoDifference(
              try Image.order(by: \.id).fetchAll(db),
              [
                Image(id: 1, image: Data("image".utf8), caption: "A good image")
              ]
            )
          }

          assertInlineSnapshot(of: relaunchedSyncEngine.container, as: .customDump) {
            """
            MockCloudContainer(
              privateCloudDatabase: MockCloudDatabase(
                databaseScope: .private,
                storage: [
                  [0]: CKRecord(
                    recordID: CKRecord.ID(1:images/zone/__defaultOwner__),
                    recordType: "images",
                    parent: nil,
                    share: nil,
                    caption: "A good image",
                    id: 1,
                    image: Data(5 bytes)
                  )
                ]
              ),
              sharedCloudDatabase: MockCloudDatabase(
                databaseScope: .shared,
                storage: []
              )
            )
            """
          }
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func outsideRecord() async throws {
        let customRecord = CKRecord(
          recordType: "customRecord",
          recordID: CKRecord.ID(
            recordName: "customRecord",
            zoneID: SyncEngine.defaultTestZone.zoneID
          )
        )
        try await syncEngine.modifyRecords(scope: .private, saving: [customRecord]).notify()
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          (No results)
          """
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func outsideRecordWithColon() async throws {
        let customRecord = CKRecord(
          recordType: "customRecord",
          recordID: CKRecord.ID(
            recordName: "1:customRecord",
            zoneID: SyncEngine.defaultTestZone.zoneID
          )
        )
        try await syncEngine.modifyRecords(scope: .private, saving: [customRecord]).notify()
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          (No results)
          """
        }
      }

      /*
       * Old device, without the "households" and "discountCards" tables, receives a household
       * record and a discount card record that references it.
       * App upgrades and creates both tables, with "discountCards" referencing "households".
       => Both records are written locally when the sync engine starts.
       */
      // NB: Without a dependency order, the new tables are processed in 'Dictionary' order, which
      //     is seeded per process and per allocation, so table names can't pin it. Each attempt
      //     builds a fresh sync engine, so the child-first order is all but certain to be hit.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: 1...10)
      func newParentAndChildTables(attempt _: Int) async throws {
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let householdRecord = householdRecord()
          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [householdRecord, discountCardRecord(household: householdRecord)]
          )
          .notify()
          syncEngine.stop()

          let relaunchedSyncEngine = try await relaunchWithHouseholdTables()
          defer { _ = relaunchedSyncEngine }

          try await userDatabase.read { db in
            expectNoDifference(try Household.fetchAll(db), [Household(id: 1, name: "Home")])
            expectNoDifference(
              try DiscountCard.fetchAll(db),
              [DiscountCard(id: 1, householdID: 1, number: "1234")]
            )
          }
          try await relaunchedSyncEngine.metadatabase.read { db in
            try #expect(UnsyncedRecordID.count().fetchOne(db) == 0)
            try #expect(Self.cachedHouseholdRecordTypeCount(db) == 2)
          }
        }
      }

      /*
       * Old device, without the "households" and "discountCards" tables, receives a discount card
       * record but not yet the household record it references.
       * App upgrades and creates both tables.
       => The sync engine still starts and caches the new schema.
       * Household record arrives.
       => Discount card record is retried and written locally.
       */
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func newChildTableWithoutParentRecord() async throws {
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          let householdRecord = householdRecord()
          _ = try syncEngine.modifyRecords(scope: .private, saving: [householdRecord])
          try await syncEngine.modifyRecords(
            scope: .private,
            saving: [discountCardRecord(household: householdRecord)]
          )
          .notify()
          syncEngine.stop()

          let relaunchedSyncEngine = try await relaunchWithHouseholdTables()
          defer { _ = relaunchedSyncEngine }

          try await userDatabase.read { db in
            try #expect(DiscountCard.fetchCount(db) == 0)
          }
          try await relaunchedSyncEngine.metadatabase.read { db in
            let unsyncedRecords = try UnsyncedRecordID.all.fetchAll(db)
            #expect(
              unsyncedRecords.map(\.recordName) == [DiscountCard.recordID(for: 1).recordName]
            )
            #expect(unsyncedRecords.first?.record?.encryptedValues["number"] as? String == "1234")
            try #expect(Self.cachedHouseholdRecordTypeCount(db) == 2)
          }

          let freshHouseholdRecord = try relaunchedSyncEngine.private.database.record(
            for: Household.recordID(for: 1)
          )
          try await relaunchedSyncEngine
            .modifyRecords(scope: .private, saving: [freshHouseholdRecord])
            .notify()

          try await userDatabase.read { db in
            expectNoDifference(try Household.fetchAll(db), [Household(id: 1, name: "Home")])
            expectNoDifference(
              try DiscountCard.fetchAll(db),
              [DiscountCard(id: 1, householdID: 1, number: "1234")]
            )
          }
          try await relaunchedSyncEngine.metadatabase.read { db in
            try #expect(UnsyncedRecordID.count().fetchOne(db) == 0)
          }
        }
      }

      private func householdRecord() -> CKRecord {
        let record = CKRecord(recordType: Household.tableName, recordID: Household.recordID(for: 1))
        record.setValue(1, forKey: "id", at: now)
        record.setValue("Home", forKey: "name", at: now)
        return record
      }

      private func discountCardRecord(household: CKRecord) -> CKRecord {
        let record = CKRecord(
          recordType: DiscountCard.tableName,
          recordID: DiscountCard.recordID(for: 1)
        )
        record.setValue(1, forKey: "id", at: now)
        record.setValue(1, forKey: "householdID", at: now)
        record.setValue("1234", forKey: "number", at: now)
        record.parent = CKRecord.Reference(record: household, action: .none)
        return record
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func relaunchWithHouseholdTables() async throws -> SyncEngine {
        try await userDatabase.userWrite { db in
          try #sql(
            """
            CREATE TABLE "households" (
              "id" INTEGER PRIMARY KEY NOT NULL,
              "name" TEXT NOT NULL
            ) STRICT
            """
          )
          .execute(db)
          try #sql(
            """
            CREATE TABLE "discountCards" (
              "id" INTEGER PRIMARY KEY NOT NULL,
              "householdID" INTEGER NOT NULL REFERENCES "households"("id") ON DELETE CASCADE,
              "number" TEXT NOT NULL
            ) STRICT
            """
          )
          .execute(db)
        }
        return try await SyncEngine(
          container: syncEngine.container,
          userDatabase: syncEngine.userDatabase,
          tables: syncEngine.tables + [
            SynchronizedTable(for: DiscountCard.self),
            SynchronizedTable(for: Household.self),
          ],
          privateTables: syncEngine.privateTables
        )
      }

      private static func cachedHouseholdRecordTypeCount(_ db: Database) throws -> Int {
        try RecordType
          .where { $0.tableName.in([Household.tableName, DiscountCard.tableName]) }
          .fetchCount(db)
      }
    }
  }

@Table("remindersLists")
private struct RemindersListWithPosition: Equatable, Identifiable {
  let id: Int
  var title = ""
  var position = 0
}

  @Table("remindersLists")
  private struct RemindersListWithColor: Equatable, Identifiable {
    let id: Int
    var title = ""
    var color: Int?
  }

  @Table("reminders")
  private struct ReminderWithPosition: Equatable, Identifiable {
    let id: Int
    var title = ""
    var position = 0
    var remindersListID: RemindersList.ID
  }

  @Table("remindersLists")
  private struct RemindersListWithData: Equatable, Identifiable {
    let id: Int
    var image: Data
    var title = ""
  }

  @Table
  private struct Image: Equatable, Identifiable {
    let id: Int
    var image: Data
    var caption = ""
  }

  @Table
  private struct Household: Equatable, Identifiable {
    let id: Int
    var name = ""
  }

  @Table
  private struct DiscountCard: Equatable, Identifiable {
    let id: Int
    var householdID: Household.ID
    var number = ""
  }
#endif
