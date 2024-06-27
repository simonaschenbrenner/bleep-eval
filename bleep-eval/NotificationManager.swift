//
//  NotificationManager.swift
//  bleep-eval
//
//  Created by Simon Núñez Aschenbrenner on 10.06.24.
//

import Foundation
import OSLog
import SwiftData

// MARK: NotificationManager protocol

protocol NotificationManager: AnyObject {
    
    var evaluationLogger: EvaluationLogger? { get set }
        
    var address: Address! { get }
    var identifier: String! { get } // TODO: should be property of the connectionManager
    var minNotificationLength: Int! { get }
    var maxMessageLength: Int! { get }
    var acknowledgementLength: Int! { get }
    var inbox: [Notification]! { get }
    
    func receiveNotification(data: Data)
    func receiveAcknowledgement(data: Data)
    func sendNotifications()
    
    func create(destinationAddress: Address, message: String) -> Notification
    func insert(_ notification: Notification)
    func save()
    
}

// MARK: Epidemic superclass

@Observable
class Epidemic: NotificationManager {
    
    final var evaluationLogger: EvaluationLogger?
    let protocolValue: UInt8!
        
    final private var container: ModelContainer!
    final private var context: ModelContext!
    final private let sendablePredicate = #Predicate<Notification> { return $0.destinationControlValue != 0 }
    
    final private(set) var address: Address!
    final private(set) var identifier: String!
    final fileprivate var connectionManager: ConnectionManager!
    
    private(set) var minNotificationLength: Int!
    private(set) var maxMessageLength: Int!
    private(set) var acknowledgementLength: Int!
    
    final private(set) var inbox: [Notification]! = []
    final fileprivate var receivedHashedIDs: [Data]! = []
    final private(set) var sendQueue: [Notification: Bool]! = [:] // Specific for each peer subscription
    final fileprivate var acknowledgedHashedIDs: [Data]! = []
        
    // MARK: initializing methods
    
    fileprivate init(protocolValue: UInt8, connectionManagerType: ConnectionManager.Type) {
        Logger.notification.trace("NotificationManager initializes")
        self.protocolValue = protocolValue
        self.container = try! ModelContainer(for: Notification.self, Address.self)
        self.context = ModelContext(self.container)
        self.context.autosaveEnabled = true
        resetContext(notifications: true)
        initAddress()
        updateIdentifier()
        self.connectionManager = connectionManagerType.init(notificationManager: self)
        self.minNotificationLength = 105
        self.maxMessageLength = self.connectionManager.maxNotificationLength - self.minNotificationLength
        self.acknowledgementLength = 32
        updateInbox()
        populateReceivedHashedIDsArray()
        Logger.notification.trace("NotificationManager with protocolValue \(self.protocolValue) initialized")
    }
    
    convenience init(connectionManagerType: ConnectionManager.Type) {
        self.init(protocolValue: 0, connectionManagerType: connectionManagerType)
    }
    
    final private func initAddress() {
        Logger.notification.trace("NotificationManager initializes its address")
        let fetchResult = try? context.fetch(FetchDescriptor<Address>(predicate: #Predicate<Address> { return $0.isOwn == true }))
        if fetchResult == nil || fetchResult!.isEmpty {
            Logger.notification.info("NotificationManager is creating a new address for itself")
            let address = Address()
            context.insert(address)
            self.address = address
        } else {
            self.address = fetchResult![0]
            Logger.notification.trace("NotificationManager found its address in storage")
        }
        if let name = Utils.addressBook.first(where: { $0 == self.address })?.name {
            self.address.name = name
            Logger.notification.trace("NotificationManager found its name in the addressBook")
        } else {
            Logger.notification.warning("NotificationManager did not find its name in the addressBook")
        }
        save()
        Logger.notification.debug("NotificationManager address: \(self.address!.description)")
    }
    
    final private func resetContext(notifications: Bool = false, address: Bool = false) {
        Logger.notification.debug("NotificationManager attempts to \(#function): notifications=\(notifications), address=\(address)")
        if notifications { try! self.context.delete(model: Notification.self) }
        if address { try! self.context.delete(model: Address.self) }
    }
        
    // MARK: receiving methods
    
    final fileprivate func populateReceivedHashedIDsArray() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let hashedIDs = fetchAllHashedIDs()
        if hashedIDs == nil || hashedIDs!.isEmpty {
            Logger.notification.debug("NotificationManager has no hashedIDs to add to the receivedHashedIDs array")
        } else {
            receivedHashedIDs = hashedIDs!
            Logger.notification.debug("NotificationManager has successfully populated the receivedHashedIDs array with \(self.receivedHashedIDs.count) hashedIDs")
        }
    }
    
    final func receiveNotification(data: Data) {
        Logger.notification.debug("NotificationManager attempts to \(#function) of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
        guard data.count >= minNotificationLength else { // TODO: handle
            Logger.notification.error("NotificationManager will ignore the notification data as it's not at least \(self.minNotificationLength) bytes long")
            return
        }
        let controlByte = ControlByte(value: UInt8(data[0]))
        let hashedID = data.subdata(in: 1..<33)
        let hashedDestinationAddress = data.subdata(in: 33..<65)
        let hashedSourceAddress = data.subdata(in: 65..<97)
        let sentTimestampData = data.subdata(in: 97..<105)
        let messageData = data.subdata(in: 105..<data.count)
        let message: String = String(data: messageData, encoding: .utf8) ?? ""
        guard controlByte.destinationControlValue > 0 else {
            Logger.notification.info("NotificationManager successfully received endOfNotificationsSignal")
            save()
            connectionManager.disconnect()
            return
        }
        guard !receivedHashedIDs.contains(hashedID) else {
            Logger.notification.info("NotificationManager will ignore notification #\(Utils.printID(hashedID)) as it is already stored")
            return
        }
        guard controlByte.destinationControlValue < 2 || hashedDestinationAddress == self.address.hashed else {
            Logger.notification.info("NotificationManager will ignore notification #\(Utils.printID(hashedID)), as its destinationControlValue is 2 and its hashedDestinationAddress (\(Utils.printID(hashedDestinationAddress))) doesn't match the hashed notificationManager address (\(Utils.printID(self.address.hashed)))")
            return
        }
        guard controlByte.protocolValue == protocolValue else { // TODO: handle
            Logger.notification.error("NotificationManager will ignore notification #\(Utils.printID(hashedID)), as its protocolValue \(controlByte.protocolValue) doesn't match the notificationManager protocolValue \(self.protocolValue)")
            return
        }
        Logger.notification.trace("NotificationManager appends notification #\(Utils.printID(hashedID)) to the receivedHashedIDs array")
        receivedHashedIDs.append(hashedID)
        receiveNotification(Notification(controlByte: controlByte, hashedID: hashedID, hashedDestinationAddress: hashedDestinationAddress, hashedSourceAddress: hashedSourceAddress, sentTimestampData: sentTimestampData, message: message))
    }
    
    fileprivate func receiveNotification(_ notification: Notification) {
        insert(notification)
        Logger.notification.info("NotificationManager successfully received notification \(notification.description) with message: '\(notification.message)'")
        updateInbox(with: notification)
    }
    
    func receiveAcknowledgement(data: Data) { // TODO: handle
        Logger.notification.warning("NotificationManager does not support \(#function)")
        return
    }
    
    // MARK: sending methods
    
    final func sendNotifications() {
        Logger.notification.trace("NotificationManager may attempt to \(#function)")
        if sendQueue.isEmpty { populateSendQueue() }
        Logger.notification.debug("NotificationManager attempts to \(#function) with \(self.sendQueue.values.filter { !$0 }.count)/\(self.sendQueue.count) unsent notifications in the sendQueue")
        for element in sendQueue {
            guard !element.value else {
                Logger.notification.trace("NotificationManager skips sending notification #\(Utils.printID(element.key.hashedID)) because it is marked as sent")
                continue
            }
            if sendNotification(element.key) {
                sendQueue[element.key] = true
                continue
            } else {
                return // peripheralManagerIsReady(toUpdateSubscribers) will call sendNotifications() again
            }
        }
        Logger.notification.trace("NotificationManager skipped or finished the \(#function) loop successfully")
        sendEndOfNotificationsSignal()
    }
    
    final fileprivate func populateSendQueue() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let notifications = fetchAllSendable()
        if notifications == nil || notifications!.isEmpty {
            Logger.notification.debug("NotificationManager has no notifications to add to the sendQueue")
        } else {
            self.sendQueue = notifications!.reduce(into: [Notification: Bool]()) { $0[$1] = false }
            Logger.notification.debug("NotificationManager has successfully populated the sendQueue with \(self.sendQueue.count) notification(s): \(self.sendQueue)")
        }
    }
    
    fileprivate func sendNotification(_ notification: Notification) -> Bool {
        Logger.notification.debug("NotificationManager attempts to \(#function) \(notification.description) with message: '\(notification.message)'")
        var data = Data()
        data.append(notification.controlByte)
        data.append(notification.hashedID)
        data.append(notification.hashedDestinationAddress)
        data.append(notification.hashedSourceAddress)
        data.append(notification.sentTimestampData)
        assert(data.count == minNotificationLength)
        if let messageData = notification.message.data(using: .utf8) { data.append(messageData) }
        if connectionManager.send(notification: data) {
            Logger.notification.info("NotificationManager successfully sent notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return true
        } else {
            Logger.notification.warning("NotificationManager did not send notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return false
        }
    }
    
    final fileprivate func sendEndOfNotificationsSignal() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 0, sequenceNumberValue: 0)
        var data = Data()
        data.append(controlByte.value)
        data.append(Data(count: minNotificationLength-data.count))
        assert(data.count == minNotificationLength)
        if connectionManager.send(notification: data) {
            Logger.notification.info("NotificationManager successfully sent \(data.count) zeros and will remove all notifications from the sendQueue")
            self.sendQueue.removeAll()
        } else {
            Logger.notification.warning("NotificationManager did not send \(data.count) zeros")
            // peripheralManagerIsReady(toUpdateSubscribers) will call sendNotifications() again
        }
    }
    
    // MARK: creation methods
    
    func create(destinationAddress: Address, message: String) -> Notification {
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 1, sequenceNumberValue: 0)
        return Notification(controlByte: controlByte, sourceAddress: self.address, destinationAddress: destinationAddress, message: message)
    }
    
    // MARK: counting methods
    
    final fileprivate func fetchAllSendableCount() -> Int {
        Logger.notification.debug("NotificationManager attempts to \(#function)")
        let result = try? context.fetchCount(FetchDescriptor<Notification>(predicate: sendablePredicate))
        return result ?? 0
    }
    
    // MARK: fetching methods
    
    final fileprivate func fetchAll() -> [Notification]? {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        return try? context.fetch(FetchDescriptor<Notification>())
    }
    
    final fileprivate func fetchAllSendable() -> [Notification]? {
        Logger.notification.debug("NotificationManager attempts to \(#function)")
        return try? context.fetch(FetchDescriptor<Notification>(predicate: sendablePredicate))
    }
    
    final fileprivate func fetchAll(for hashedAddress: Data) -> [Notification]? {
        Logger.notification.debug("NotificationManager attempts to \(#function) for hashedAddress (\(Utils.printID(hashedAddress)))")
        let predicate = #Predicate<Notification> { $0.hashedDestinationAddress == hashedAddress }
        return try? context.fetch(FetchDescriptor<Notification>(predicate: predicate))
    }
    
    final fileprivate func fetchAllHashedIDs() -> [Data]? {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        guard let results = fetchAll() else { return nil }
        return results.map { $0.hashedID }
    }
    
    final fileprivate func fetch(with hashedID: Data) -> Notification? {
        Logger.notification.debug("NotificationManager attempts to \(#function) #\(Utils.printID(hashedID))")
        let fetchDescriptor = FetchDescriptor<Notification>(predicate: #Predicate { notification in notification.hashedID == hashedID })
        return try? context.fetch(fetchDescriptor)[0]
    }
    
    // MARK: insertion methods
    
    final func insert(_ notification: Notification) {
        Logger.notification.debug("NotificationManager attempts to \(#function) notification #\(Utils.printID(notification.hashedID))")
        if notification.hashedDestinationAddress == self.address.hashed { // TODO: In the future we may want to handle the notification as any other and resend it to obfuscate it was meant for us
            try! notification.setDestinationControl(to: 0)
            Logger.notification.info("NotificationManager has setDestinationControl(to: 0) for notification #\(Utils.printID(notification.hashedID)) because its hashedDestinationAddress matches the hashed notificationManager address")
        }
        if evaluationLogger == nil {
            Logger.notification.warning("NotificationManager did not call evaluationLogger.log() because the evaluationLogger property is nil")
        } else {
            evaluationLogger!.log(notification, at: self.address)
        }
        context.insert(notification)
        updateIdentifier()
    }
    
    final private func updateIdentifier() {
        Logger.notification.trace("NotificationManager attempts to \(#function) and may attempt to advertise")
        identifier = String(Address().base58Encoded.suffix(8))
        guard connectionManager != nil else { // TODO: handle
            Logger.bluetooth.warning("NotificationManager won't attempt to advertise because its connectionManager property is nil")
            return
        }
        connectionManager.advertise()
    }
    
    final func save() {
        do {
            try context.save()
            Logger.notification.trace("NotificationManager saved the context")
        } catch {
            Logger.notification.fault("NotificationManager failed to save the context: \(error)")
        }
    }
    
    // MARK: inbox methods
    
    final fileprivate func updateInbox() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let countBefore = inbox.count
        save()
        inbox = fetchAll(for: self.address.hashed) ?? []
        Logger.notification.debug("NotificationManager added \(self.inbox.count - countBefore) notification(s) to the inbox")
    }
    
    final fileprivate func updateInbox(with notification: Notification) {
        Logger.notification.debug("NotificationManager attempts to \(#function) notification #\(Utils.printID(notification.hashedID))")
        guard notification.hashedDestinationAddress == self.address.hashed else { // TODO: handle
            Logger.notification.warning("NotificationManager won't \(#function) notification #\(Utils.printID(notification.hashedID)) because its hashedDestinationAddress doesn't match the hashed notificationManager address")
            return
        }
        let countBefore = inbox.count
        save()
        inbox.insert(notification, at: 0)
        Logger.notification.debug("NotificationManager added \(self.inbox.count - countBefore) notification to the inbox")
    }
    
    // TODO: deletion methods
}

// MARK: Spray and Wait subclass

@Observable
class BinarySprayAndWait: Epidemic {
    
    private(set) var numberOfCopies: Int! // L

    init(connectionManagerType: ConnectionManager.Type, numberOfCopies: Int) throws {
        super.init(protocolValue: 1, connectionManagerType: connectionManagerType)
        guard numberOfCopies < 16 else {
            throw BleepError.invalidControlByteValue
        }
        self.numberOfCopies = numberOfCopies
    }
    
    // MARK: receiving methods
    
    override fileprivate func receiveNotification(_ notification: Notification) {
        insert(notification)
        connectionManager.acknowledge(hashedID: notification.hashedID)
        Logger.notification.info("BinarySprayAndWaitNotificationManager successfully received notification \(notification.description) with message: '\(notification.message)'")
        updateInbox(with: notification)
    }
    
    override func receiveAcknowledgement(data: Data) {
        Logger.notification.debug("BinarySprayAndWaitNotificationManager attempts to \(#function) of \(data.count) bytes")
        guard data.count == acknowledgementLength else { // TODO: handle
            Logger.notification.warning("BinarySprayAndWaitNotificationManager will ignore the acknowledgement data as it's not \(self.acknowledgementLength) bytes long")
            return
        }
        guard let notification = fetch(with: data) else { // TODO: handle
            Logger.notification.warning("BinarySprayAndWaitNotificationManager did not find a matching notification in storage")
            return
        }
        do {
            try notification.setSequenceNumber(to: notification.sequenceNumberValue/2)
            Logger.notification.info("BinarySprayAndWaitNotificationManager halfed the sequenceNumberValue of notification \(notification.description)")
        } catch {
            try! notification.setDestinationControl(to: 2)
            Logger.notification.info("BinarySprayAndWaitNotificationManager could not half the sequenceNumberValue and therefore has set setDestinationControl(to: 2) for notification \(notification.description)")
        }
    }
    
    // MARK: sending methods
    
    override fileprivate func sendNotification(_ notification: Notification) -> Bool {
        Logger.notification.debug("BinarySprayAndWaitNotificationManager attempts to sendNotification \(notification.description) with a newControlByte")
        var newControlByte: ControlByte!
        do {
            newControlByte = try ControlByte(protocolValue: notification.protocolValue, destinationControlValue: notification.destinationControlValue, sequenceNumberValue: notification.sequenceNumberValue/2)
            Logger.notification.trace("BinarySprayAndWaitNotificationManager halfed the sequenceNumberValue of the newControlByte")
        } catch BleepError.invalidControlByteValue {
            newControlByte = try! ControlByte(protocolValue: notification.protocolValue, destinationControlValue: 2, sequenceNumberValue: notification.sequenceNumberValue)
            Logger.notification.trace("BinarySprayAndWaitNotificationManager could not half the sequenceNumberValue and has therefore setDestinationControl(to: 2) for the newControlByte")
        } catch {
            Logger.notification.error("BinarySprayAndWaitNotificationManager encountered an unexpected error while trying to create a newControlByte")
        }
        Logger.notification.debug("Notification #\(Utils.printID(notification.hashedID)) newControlByte: \(newControlByte.description)")
        var data = Data()
        data.append(newControlByte.value)
        data.append(notification.hashedID)
        data.append(notification.hashedDestinationAddress)
        data.append(notification.hashedSourceAddress)
        data.append(notification.sentTimestampData)
        assert(data.count == minNotificationLength)
        if let messageData = notification.message.data(using: .utf8) {
            data.append(messageData)
        }
        if connectionManager.send(notification: data) {
            Logger.notification.info("BinarySprayAndWaitNotificationManager successfully sent notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return true
        } else {
            Logger.notification.warning("BinarySprayAndWaitNotificationManager did not send notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return false
        }
    }
    
    // MARK: creation methods
    
    override func create(destinationAddress: Address, message: String) -> Notification {
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 1, sequenceNumberValue: UInt8(self.numberOfCopies))
        return Notification(controlByte: controlByte, sourceAddress: self.address, destinationAddress: destinationAddress, message: message)
    }
    
}
