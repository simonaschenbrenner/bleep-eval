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
    
    // For simulation/evaluation
    var evaluationLogger: EvaluationLogger? { get set }
    var rssiThreshold: Int8! { get set }
    var receivedHashedIDs: Set<Data>! { get }
    func setNumberOfCopies(to: UInt8) throws

    var address: Address! { get }
    var contacts: [Address]! { get }
    var maxMessageLength: Int! { get }
    var inbox: [Notification]! { get }
    func receiveNotification(_ data: Data)
    func receiveAcknowledgement(_ data: Data) -> Bool
    func transmitNotifications()
    func send(_ message: String, to destinationAddress: Address)
    
}

// MARK: Direct superclass

@Observable
class Direct: NotificationManager {
    
    let minNotificationLength: Int = 105
    let protocolValue: UInt8!
    
    final var evaluationLogger: EvaluationLogger?
    final var rssiThreshold: Int8! = -128
    
    final private(set) var maxMessageLength: Int!
    final private(set) var address: Address!
    final private(set) var contacts: [Address]!
    final private(set) var inbox: [Notification]! = []
    final private(set) var receivedHashedIDs: Set<Data>! = []
    
    final fileprivate var transmitQueue: [Notification: Bool]! = [:]
    final fileprivate var connectionManager: ConnectionManager!
    final fileprivate var container: ModelContainer!
    final fileprivate var context: ModelContext!
    
    // MARK: initializing methods
    
    fileprivate init(protocolValue: UInt8, connectionManagerType: ConnectionManager.Type) {
        Logger.notification.trace("NotificationManager initializes")
        self.protocolValue = protocolValue
        self.container = try! ModelContainer(for: Notification.self, Address.self)
        self.context = ModelContext(self.container)
        self.context.autosaveEnabled = true
        resetContext(notifications: true)
        initAddress()
        initContacts()
        self.connectionManager = connectionManagerType.init(notificationManager: self)
        self.maxMessageLength = self.connectionManager.maxNotificationLength - self.minNotificationLength
        updateInbox()
        populateReceivedHashedIDsArray()
        Logger.notification.trace("NotificationManager with protocolValue \(self.protocolValue) initialized")
    }
    
    convenience init(connectionManagerType: ConnectionManager.Type) {
        self.init(protocolValue: 0, connectionManagerType: connectionManagerType)
    }
    
    final private func resetContext(notifications: Bool = false, address: Bool = false) {
        Logger.notification.debug("NotificationManager attempts to \(#function): notifications=\(notifications), address=\(address)")
        if notifications { try! self.context.delete(model: Notification.self) }
        if address { try! self.context.delete(model: Address.self) }
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
            Logger.notification.fault("NotificationManager did not find its name in the addressBook")
        }
        save()
        Logger.notification.debug("NotificationManager address: \(self.address!.description)")
    }
    
    final private func initContacts() {
        contacts = Utils.addressBook.filter({ $0 != address })
        Logger.notification.trace("NotificationManager initialized its contacts: \(self.contacts)")
    }
    
    func setNumberOfCopies(to: UInt8) throws {
        Logger.notification.error("NotificationManager does not support \(#function)")
    }
    
    // MARK: receiving methods
    
    final func receiveNotification(_ data: Data) {
        Logger.notification.debug("NotificationManager attempts to \(#function) of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
        guard data.count >= minNotificationLength else { // TODO: throw
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
            connectionManager.disconnect()
            return
        }
        guard controlByte.protocolValue == protocolValue else { // TODO: throw
            Logger.notification.error("NotificationManager will ignore notification #\(Utils.printID(hashedID)), as its protocolValue \(controlByte.protocolValue) doesn't match the notificationManager protocolValue \(self.protocolValue)")
            return
        }
        guard !receivedHashedIDs.contains(hashedID) else {
            Logger.notification.info("NotificationManager will ignore notification #\(Utils.printID(hashedID)) as it is already stored")
            return
        }
        let notification = Notification(controlByte: controlByte, hashedID: hashedID, hashedDestinationAddress: hashedDestinationAddress, hashedSourceAddress: hashedSourceAddress, sentTimestampData: sentTimestampData, message: message)
        guard accept(notification) else {
            Logger.notification.info("NotificationManager will ignore notification #\(Utils.printID(hashedID)) as accept(notification) returned false")
            return
        }
        Logger.notification.trace("NotificationManager appends hashedID #\(Utils.printID(hashedID)) to the receivedHashedIDs set")
        receivedHashedIDs.insert(hashedID)
        Logger.notification.info("NotificationManager successfully received notification \(notification.description) with message: '\(notification.message)'")
        if notification.hashedDestinationAddress == self.address.hashed { // TODO: In the future we may want to handle the notification as any other and resend it to obfuscate it was meant for us
            try! notification.setDestinationControl(to: 0)
            Logger.notification.info("NotificationManager has setDestinationControl(to: 0) for notification #\(Utils.printID(notification.hashedID)) because it reached its destination")
            updateInbox(with: notification)
        }
        if evaluationLogger == nil {
            Logger.notification.warning("NotificationManager did not call evaluationLogger.log() because the evaluationLogger property is nil")
        } else {
            evaluationLogger!.log(notification, at: self.address)
        }
        insert(notification)
    }
    
    func receiveAcknowledgement(_ data: Data) -> Bool {
        Logger.notification.error("NotificationManager does not support \(#function)")
        return false
    }
    
    fileprivate func accept(_ notification: Notification) -> Bool {
        return notification.destinationControlValue == 2 && notification.hashedDestinationAddress == self.address.hashed
    }
    
    final fileprivate func populateReceivedHashedIDsArray() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let hashedIDs = fetchAllHashedIDs()
        if hashedIDs == nil || hashedIDs!.isEmpty {
            Logger.notification.debug("NotificationManager has no hashedIDs to add to the receivedHashedIDs set")
        } else {
            receivedHashedIDs = Set(hashedIDs!)
            Logger.notification.debug("NotificationManager has successfully populated the receivedHashedIDs set with \(self.receivedHashedIDs.count) hashedIDs")
        }
    }
    
    final fileprivate func updateInbox() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let countBefore = inbox.count
        inbox = fetchAll(for: self.address.hashed) ?? []
        Logger.notification.debug("NotificationManager added \(self.inbox.count - countBefore) notification(s) to the inbox")
    }
    
    final fileprivate func updateInbox(with notification: Notification) {
        Logger.notification.debug("NotificationManager attempts to \(#function) notification #\(Utils.printID(notification.hashedID))")
// TODO: uncomment when check doesn't happen in receiveNotification(_ data: Data)
//        guard notification.hashedDestinationAddress == self.address.hashed else {
//            Logger.notification.debug("NotificationManager won't \(#function) notification #\(Utils.printID(notification.hashedID)) because its hashedDestinationAddress doesn't match the hashed notificationManager address")
//            return
//        }
        let countBefore = inbox.count
        inbox.append(notification)
        Logger.notification.debug("NotificationManager added \(self.inbox.count - countBefore) notification to the inbox")
    }
    
    // MARK: sending methods
    
    final func transmitNotifications() {
        Logger.notification.trace("NotificationManager may attempt to \(#function)")
        if transmitQueue.isEmpty { populateTransmitQueue() }
        Logger.notification.debug("NotificationManager attempts to \(#function) with \(self.transmitQueue.values.filter { !$0 }.count)/\(self.transmitQueue.count) notifications in the transmitQueue")
        for element in transmitQueue {
            guard !element.value else {
                Logger.notification.trace("NotificationManager skips transmitting notification #\(Utils.printID(element.key.hashedID)) because it was already transmitted")
                continue
            }
            if transmit(element.key) {
                transmitQueue[element.key] = true
                if evaluationLogger == nil {
                    Logger.notification.warning("NotificationManager did not call evaluationLogger.log() because the evaluationLogger property is nil")
                } else {
                    evaluationLogger!.log(element.key, at: self.address)
                }
                continue
            } else {
                return // peripheralManagerIsReady(toUpdateSubscribers) will call transmitNotifications() again
            }
        }
        Logger.notification.trace("NotificationManager skipped or finished the \(#function) loop successfully")
        transmitEndOfNotificationsSignal()
    }
    
    func send(_ message: String, to destinationAddress: Address) {
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 2, sequenceNumberValue: 0)
        insert(Notification(controlByte: controlByte, sourceAddress: self.address, destinationAddress: destinationAddress, message: message))
    }
    
    fileprivate func transmit(_ notification: Notification) -> Bool {
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
            Logger.notification.info("NotificationManager successfully transmitted notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return true
        } else {
            Logger.notification.warning("NotificationManager did not transmit notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return false
        }
    }
    
    final fileprivate func populateTransmitQueue() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let notifications = fetchAllTransmittable()
        if notifications == nil || notifications!.isEmpty {
            Logger.notification.debug("NotificationManager has no notifications to add to the transmitQueue")
        } else {
            self.transmitQueue = notifications!.reduce(into: [Notification: Bool]()) { $0[$1] = false }
            Logger.notification.debug("NotificationManager has successfully populated the transmitQueue with \(self.transmitQueue.count) notification(s): \(self.transmitQueue)")
        }
    }

    final fileprivate func transmitEndOfNotificationsSignal() {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 0, sequenceNumberValue: 0)
        var data = Data()
        data.append(controlByte.value)
        data.append(Data(count: minNotificationLength-data.count))
        assert(data.count == minNotificationLength)
        if connectionManager.send(notification: data) {
            Logger.notification.info("NotificationManager successfully transmitted \(data.count) zeros and will remove all notifications from the sendQueue")
            self.transmitQueue.removeAll()
        } else {
            Logger.notification.warning("NotificationManager did not transmit \(data.count) zeros")
            // peripheralManagerIsReady(toUpdateSubscribers) will call transmitNotifications() again
        }
    }
    
    // MARK: persistence methods
    
    final fileprivate func fetchAll() -> [Notification]? {
        Logger.notification.trace("NotificationManager attempts to \(#function)")
        return try? context.fetch(FetchDescriptor<Notification>())
    }
    
    final fileprivate func fetchAllTransmittable() -> [Notification]? {
        Logger.notification.debug("NotificationManager attempts to \(#function)")
        return try? context.fetch(FetchDescriptor<Notification>(predicate: #Predicate<Notification> { return $0.destinationControlValue != 0 }))
    }
    
    final fileprivate func fetchAllTransmittableCount() -> Int {
        Logger.notification.debug("NotificationManager attempts to \(#function)")
        let result = try? context.fetchCount(FetchDescriptor<Notification>(predicate: #Predicate<Notification> { return $0.destinationControlValue != 0 }))
        return result ?? 0
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
        
    final func insert(_ notification: Notification) {
        Logger.notification.debug("NotificationManager attempts to \(#function) notification #\(Utils.printID(notification.hashedID))")
        context.insert(notification)
        save()
        connectionManager.advertise(with: String(Address().base58Encoded.suffix(8)))
    }
    
    final private func save() {
        do {
            try context.save()
            Logger.notification.trace("NotificationManager saved the context")
        } catch { // TODO: throw
            Logger.notification.error("NotificationManager failed to save the context: \(error)")
        }
    }
    // TODO: deletion methods
}

// MARK: Epidemic subclass

@Observable
class Epidemic: Direct {
    
    // MARK: initializing methods
        
    convenience init(connectionManagerType: ConnectionManager.Type) {
        self.init(protocolValue: 1, connectionManagerType: connectionManagerType)
    }
        
    // MARK: receiving methods
    
    override fileprivate func accept(_ notification: Notification) -> Bool {
        return notification.destinationControlValue == 1
    }
        
    // MARK: sending methods
    
    override func send(_ message: String, to destinationAddress: Address) {
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 1, sequenceNumberValue: 0)
        insert(Notification(controlByte: controlByte, sourceAddress: self.address, destinationAddress: destinationAddress, message: message))
    }
    
}

// MARK: Spray and Wait subclass

@Observable
class BinarySprayAndWait: Epidemic {
    
    let acknowledgementLength: Int = 32
    private var numberOfCopies: UInt8! // L

    init(connectionManagerType: ConnectionManager.Type, numberOfCopies: UInt8) throws {
        super.init(protocolValue: 2, connectionManagerType: connectionManagerType)
        try self.setNumberOfCopies(to: numberOfCopies)
    }
    
    override func setNumberOfCopies(to value: UInt8) throws {
        Logger.notification.debug("BinarySprayAndWait attempts to \(#function) \(value)")
        guard value < 16 else {
            throw BleepError.invalidControlByteValue
        }
        self.numberOfCopies = value
    }
    
    // MARK: receiving methods
    
    override func receiveAcknowledgement(_ data: Data) -> Bool {
        Logger.notification.debug("BinarySprayAndWait NotificationManager attempts to \(#function) of \(data.count) bytes")
        guard data.count == self.acknowledgementLength else { // TODO: throw
            Logger.notification.error("BinarySprayAndWait NotificationManager will ignore the acknowledgement data as it's not \(self.acknowledgementLength) bytes long")
            return false
        }
        guard let notification = fetch(with: data) else { // TODO: throw
            Logger.notification.error("BinarySprayAndWait NotificationManager did not find a matching notification in storage")
            return false
        }
        do {
            try notification.setSequenceNumber(to: notification.sequenceNumberValue/2)
            Logger.notification.info("BinarySprayAndWait NotificationManager halfed the sequenceNumberValue of notification \(notification.description)")
            return true
        } catch {
            try! notification.setDestinationControl(to: 2) // TODO: throw
            Logger.notification.error("BinarySprayAndWait NotificationManager could not half the sequenceNumberValue and therefore has set setDestinationControl(to: 2) for notification \(notification.description)")
            return false
        }
    }
    
    override fileprivate func accept(_ notification: Notification) -> Bool {
        if notification.destinationControlValue == 1 || notification.hashedDestinationAddress == self.address.hashed {
            acknowledge(notification)
            return true
        } else {
            return false
        }
    }
    
    private func acknowledge(_ notification: Notification) {
        Logger.notification.debug("BinarySprayAndWait NotificationManager attempts to \(#function) #\(Utils.printID(notification.hashedID))")
        connectionManager.acknowledge(hashedID: notification.hashedID)
    }
    
    // MARK: sending methods
    
    override func send(_ message: String, to destinationAddress: Address) {
        let controlByte = try! ControlByte(protocolValue: self.protocolValue, destinationControlValue: 1, sequenceNumberValue: self.numberOfCopies)
        insert(Notification(controlByte: controlByte, sourceAddress: self.address, destinationAddress: destinationAddress, message: message))
    }
    
    override fileprivate func transmit(_ notification: Notification) -> Bool {
        Logger.notification.debug("BinarySprayAndWait NotificationManager attempts to \(#function) \(notification.description) with a newControlByte")
        var newControlByte: ControlByte!
        do {
            newControlByte = try ControlByte(protocolValue: notification.protocolValue, destinationControlValue: notification.destinationControlValue, sequenceNumberValue: notification.sequenceNumberValue/2)
            Logger.notification.trace("BinarySprayAndWait NotificationManager halfed the sequenceNumberValue of the newControlByte")
        } catch BleepError.invalidControlByteValue {
            newControlByte = try! ControlByte(protocolValue: notification.protocolValue, destinationControlValue: 2, sequenceNumberValue: notification.sequenceNumberValue)
            Logger.notification.trace("BinarySprayAndWait NotificationManager could not half the sequenceNumberValue and has therefore setDestinationControl(to: 2) for the newControlByte")
        } catch {
            Logger.notification.error("BinarySprayAndWait NotificationManager encountered an unexpected error while trying to create a newControlByte")
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
            Logger.notification.info("BinarySprayAndWait NotificationManager successfully sent notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return true
        } else {
            Logger.notification.warning("BinarySprayAndWait NotificationManager did not send notification data of \(data.count-self.minNotificationLength)+\(self.minNotificationLength)=\(data.count) bytes")
            return false
        }
    }
    
}
