//
//  ContentView.swift
//  bleep-eval
//
//  Created by Simon Núñez Aschenbrenner on 03.05.24.
//

import Foundation
import OSLog
import SwiftUI
import SwiftData

struct Font {
    struct BHTCaseMicro {
        static let Regular = "BHTCaseMicro-Regular"
        static let Italic = "BHTCaseMicro-Italic"
        static let Bold = "BHTCaseMicro-Bold"
        static let BoldItalic = "BHTCaseMicro-BoldItalic"
    }
    struct BHTCaseText {
        static let Regular = "BHTCaseText-Regular"
        static let Italic = "BHTCaseText-Italic"
        static let Bold = "BHTCaseText-Bold"
        static let BoldItalic = "BHTCaseText-BoldItalic"
    }
    struct Size {
        static let Logo = 32.0
        static let Title = 32.0
        static let Text = 16.0
    }
}

struct Dimensions {
    static let lineWidth: CGFloat = 1.0
    static let largePadding: CGFloat = Font.Size.Text
    static let mediumPadding: CGFloat = Font.Size.Text * 0.5
    static let smallPadding: CGFloat = Font.Size.Text * 0.25
    static let sendButtonSize: CGFloat = Font.Size.Text * 2
    static let singleLineHeight: CGFloat = Font.Size.Text * 2.5 // sendButtonSize + small vertical padding = Font.Size.Text + small and medium vertical padding
    static let cornerRadius: CGFloat = Font.Size.Text * 1.25 // singleLineHeight/2
    static let textEditorWidthOffset: CGFloat = 2 * lineWidth + 2 * largePadding + mediumPadding + 3 * smallPadding + sendButtonSize
}

enum NotificationManagerProtocol: String, CaseIterable, Identifiable {
    case epidemic = "Epidemic"
    case binarySprayAndWait = "Binary Spray and Wait"
    var id: Self { self }
}

// MARK: ContentView

struct ContentView: View {
    
    @State private var notificationManager: NotificationManager = try! BinarySprayAndWait(connectionManagerType: BluetoothManager.self, numberOfCopies: 15)
    @State private var showAutoView: Bool = true
    @State private var notificationManagerProtocol: NotificationManagerProtocol = .binarySprayAndWait
    
    func changeProtocol(to proto: NotificationManagerProtocol) {
        Logger.view.debug("View attempts to \(#function) \(proto.rawValue)")
        switch proto {
        case .epidemic:
            notificationManager = Epidemic(connectionManagerType: BluetoothManager.self)
        case .binarySprayAndWait:
            notificationManager = try! BinarySprayAndWait(connectionManagerType: BluetoothManager.self, numberOfCopies: 15)
        }
    }
    
    var body: some View {
        
        VStack(alignment: .leading) {
            
            // MARK: Logo
            
            ZStack {
                LogoView()
                    .padding(.vertical, Dimensions.largePadding)
                Toggle("", isOn: $showAutoView)
                    .padding(.trailing, Dimensions.largePadding)
                    .tint(Color("bleepPrimary"))
            }
            
            // MARK: Status
            
            Picker("Protocol", selection: $notificationManagerProtocol) {
                ForEach(NotificationManagerProtocol.allCases) { proto in
                    Text(proto.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding([.leading, .bottom, .trailing], Dimensions.largePadding)
            .onChange(of: notificationManagerProtocol, { changeProtocol(to: notificationManagerProtocol) })
            
            HStack(alignment: .bottom) {
                Text("I am \(addressBook.first(where: { $0 == notificationManager.address })?.description ?? "unknown")")
                    .font(.custom(Font.BHTCaseText.Regular, size: Font.Size.Text))
                    .foregroundColor(Color("bleepPrimary"))
                if notificationManager.isSubscribing {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundColor(Color("bleepPrimary"))
                } else if notificationManager.isPublishing {
                    Image(systemName: "tray.and.arrow.up.fill")
                        .foregroundColor(Color("bleepPrimary"))
                } else {
                    Image(systemName: "tray.fill")
                        .foregroundColor(Color("bleepPrimary"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Dimensions.largePadding)
            
            if showAutoView {
                AutoView(notificationManager)
            } else {
                ManualView(notificationManager)
            }
        }
        .dynamicTypeSize(DynamicTypeSize.large...DynamicTypeSize.large)
    }
}

// MARK: AutoView

struct AutoView: View {
    
    unowned var notificationManager: NotificationManager!
    @State private var runID: Int = 0
    @State private var isRunning: Bool = false
    @State private var frequency: Int = 2
    @State private var variance: Int = 1
//    private let dispatchGroup = DispatchGroup()
    
    init(_ notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }
    
    private func simulate() {
        Logger.view.info("View attempts to \(#function)")
        Logger.view.debug("Simulation runID=\(runID), frequency=\(frequency)s, variance=±\(variance*25)%")
        EvaluationLogger.instance.runID = runID
        let destinations = addressBook.filter({ $0 != notificationManager.address })
        while isRunning {
//            dispatchGroup.enter()
//            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(frequency+Int(Float(frequency)*Float.random(in: Float(-variance)/4...Float(variance)/4)))) {
                let destinationAddress = destinations.randomElement()!
                let message = generateText(with: Int.random(in: 77...maxMessageLength))
                let notification = notificationManager.create(destinationAddress: destinationAddress, message: message)
                notificationManager.insert(notification)
                notificationManager.save()
                notificationManager.decide()
//            }
            // TODO: make non blocking!
            sleep(UInt32(frequency+Int(Float(frequency)*Float.random(in: Float(-variance)/4...Float(variance)/4))))
        }
//        dispatchGroup.notify(queue: DispatchQueue.main) {
//            Logger.view.trace("View finished \(#function) loop")
//        }
    }
    
    var body: some View {
        
        // MARK: Simulation parameters
        
        List {
            Text("Simulation")
                .font(.custom(Font.BHTCaseMicro.Bold, size: Font.Size.Text))
            Stepper("Run #\(runID)", value: $runID, in: 0...Int.max)                    .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
                .foregroundColor(Color("bleepPrimary"))
            Stepper("Send every \(frequency) seconds", value: $frequency, in: 2...Int.max)                    .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
                .foregroundColor(Color("bleepPrimary"))
            Stepper("with ±\(variance*25)% variance", value: $variance, in: 0...4)
                .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
                .foregroundColor(Color("bleepPrimary"))
            Button(action: {
                if !isRunning {
                    isRunning = true
                    simulate()
                } else {
                    isRunning = false
                }
            }) {
                Text(!isRunning ? "Start" : "Stop")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Dimensions.singleLineHeight)
                    .font(.custom(Font.BHTCaseMicro.Bold, size: Font.Size.Text))
                    .background(isRunning ? Color("bleepPrimary") : Color("bleepSecondary"))
                    .foregroundColor(Color("bleepPrimaryOnPrimaryBackground"))
                    .cornerRadius(Dimensions.cornerRadius)
            }
            Text("Received \(notificationManager.inbox.count) notifications")
                .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
        }
        .scrollDisabled(true)
    }
}

// MARK: ManualView

struct ManualView: View {
    
    unowned var notificationManager: NotificationManager!
    @State private var draft: String = ""
    @State private var destinationAddress: Address? = nil
    @FocusState private var textEditorFocused: Bool
    @State private var textEditorHeight: CGFloat = Dimensions.singleLineHeight
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    
    init(_ notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }
    
    private func adjustTextEditorHeight() {
        let newHeight: CGFloat = draft.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width - Dimensions.textEditorWidthOffset, height: CGFloat.infinity),
            options: .usesLineFragmentOrigin,
            attributes: [.font: UIFont(name: Font.BHTCaseText.Regular, size: Font.Size.Text)!],
            context: nil
        ).height + 2 * Dimensions.mediumPadding
        withAnimation { textEditorHeight = newHeight }
    }
    
    private func decide() { // TODO: rename
        Logger.view.info("View attempts to \(#function)")
        if !draft.isEmpty && destinationAddress != nil {
            let notification = notificationManager.create(destinationAddress: destinationAddress!, message: draft)
            notificationManager.insert(notification)
            notificationManager.save()
            draft.removeAll()
        }
        notificationManager.decide()
    }
    
    private func getDraftCount() -> Int {
        return draft.data(using: .utf8)?.count ?? 0
    }
    
    var body: some View {

        // MARK: Destinations
        
        LazyVGrid(columns: columns) {
            ForEach(addressBook) { address in
                Button(action: {
                    if destinationAddress == address {
                        destinationAddress = nil
                    } else {
                        destinationAddress = address
                    }
                }) {
                    Text(address.name ?? address.base58Encoded)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: Dimensions.singleLineHeight)
                        .font(.custom(Font.BHTCaseMicro.Bold, size: Font.Size.Text))
                        .background(address == destinationAddress ? Color("bleepPrimary") : Color("bleepSecondary"))
                        .foregroundColor(Color("bleepPrimaryOnPrimaryBackground"))
                        .cornerRadius(Dimensions.cornerRadius)
                }
                .disabled(address == notificationManager.address)
            }
        }
        .padding(.horizontal)
        
        // MARK: Message
        
        VStack(alignment: .trailing) {
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $draft)
                .background(Color.clear)
                .frame(height: textEditorHeight)
                .padding(.leading, Dimensions.mediumPadding)
                .padding(.trailing, Dimensions.sendButtonSize + Dimensions.smallPadding)
                .padding(.bottom, Dimensions.lineWidth)
                .onChange(of: draft, initial: true) { adjustTextEditorHeight() }
                .font(.custom(Font.BHTCaseText.Regular, size: Font.Size.Text))
                .overlay(
                    Group { if draft.isEmpty {
                        Text("Select recipient and enter message")
                        .font(.custom(Font.BHTCaseText.Regular, size: Font.Size.Text))
                        .foregroundColor(Color.gray)
                        .padding(.leading, Dimensions.mediumPadding + Dimensions.smallPadding + Dimensions.lineWidth)
                        }
                    },
                    alignment: .leading
                )
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .focused($textEditorFocused)
                .onTapGesture { textEditorFocused = true }
                Button(action: decide) {
                    Image(systemName: draft.isEmpty || destinationAddress == nil ? "questionmark.circle.fill" : "arrow.up.circle.fill")
                    .resizable()
                    .frame(width: Dimensions.sendButtonSize, height: Dimensions.sendButtonSize)
                    .foregroundColor(Color("bleepPrimary"))
                }
                .padding(Dimensions.smallPadding)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Dimensions.cornerRadius)
                    .stroke(Color("bleepSecondary"), lineWidth: Dimensions.lineWidth)
            )
            .padding(.horizontal, Dimensions.largePadding)
            Button(action: {
                draft.isEmpty ? draft = generateText(with: maxMessageLength) : draft.removeAll()
                textEditorFocused = false
            }) {
                Text("\(getDraftCount())/\(maxMessageLength)")
                .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
                .foregroundColor(Color("bleepSecondary"))
            }
            .padding(.trailing, Dimensions.largePadding)
        }

        // MARK: Notifications
        
        VStack(alignment: .center) {
            Text("Received \(notificationManager.inbox.count) notifications")
                .font(.custom(Font.BHTCaseMicro.Bold, size: Font.Size.Text))
                .underline()
                .padding(.horizontal)
            List(notificationManager.inbox) { notification in
                NotificationView(notification: notification)
            }
            Spacer()
        }
    }
}

// MARK: NotificationView

struct NotificationView: View {
    let notification: Notification
    @State private var showsMetadata = false

    var body: some View {
        Button(action: {
            showsMetadata.toggle()
        }) {
            Text(displayText)
                .font(.custom(Font.BHTCaseMicro.Regular, size: Font.Size.Text))
                .foregroundColor(Color("bleepPrimary"))
        }
    }

    private var displayText: String {
        if showsMetadata {
            return notification.description
        } else {
            return notification.message
        }
    }
}

// MARK: LogoView

struct LogoView: View {
    
    let spacing = 1.5
    let height = Font.Size.Logo + 10.0
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ZStack(alignment: .trailing) {
                    Color("bleepPrimary")
                        .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
//                        .ignoresSafeArea()
                    Text("bleep")
                        .font(.custom(Font.BHTCaseMicro.Bold, size: Font.Size.Logo))
                        .foregroundColor(Color("bleepPrimaryOnPrimaryBackground"))
                        .padding(.trailing, spacing)
                }
                Text("eval")
                    .font(.custom(Font.BHTCaseText.Regular, size: Font.Size.Logo))
                    .foregroundColor(Color("bleepPrimary"))
            }
            .padding(.trailing, geometry.size.width/3)
        }
        .frame(maxHeight: height)
    }
}

#Preview {
    ContentView()
        .environment(try! BinarySprayAndWait(connectionManagerType: BluetoothManager.self, numberOfCopies: 15))
}
