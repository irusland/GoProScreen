//
//  ContentView.swift
//  GoProScreen
//
//  Created by Ruslan Sirazhetdinov on 2026-10-01.
//

import CoreBluetooth
import Combine
import Network
import SwiftUI
import WatchConnectivity

struct ContentView: View {
    @StateObject private var controller = GoProController()
    @State private var cameraAddress = "10.5.5.9"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PreviewPanel(controller: controller)

                    SectionPanel(title: "GoPro MAX 2") {
                        HStack {
                            Label(controller.bluetoothState, systemImage: controller.isScanning ? "dot.radiowaves.left.and.right" : "bolt.horizontal.circle")
                            Spacer()
                            Button {
                                controller.toggleScanning()
                            } label: {
                                Label(controller.isScanning ? "Стоп" : "Поиск", systemImage: controller.isScanning ? "stop.fill" : "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if controller.cameras.isEmpty {
                            Text("Включите режим pairing на камере. GoPro должна рекламировать BLE service FEA6.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(controller.cameras) { camera in
                                Button {
                                    controller.connect(to: camera.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(camera.name)
                                                .font(.headline)
                                            Text("RSSI \(camera.rssi)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: camera.id == controller.connectedCameraID ? "checkmark.circle.fill" : "chevron.right")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    SectionPanel(title: "Wi-Fi preview") {
                        if let credentials = controller.wifiCredentials {
                            LabeledContent("SSID", value: credentials.ssid)
                            LabeledContent("Пароль", value: credentials.password.isEmpty ? "не прочитан" : credentials.password)
                        } else {
                            Text("После BLE-подключения приложение попробует прочитать SSID и пароль Wi-Fi AP камеры.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        TextField("IP камеры", text: $cameraAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button {
                                Task { await controller.startPreview(cameraAddress: cameraAddress) }
                            } label: {
                                Label("Старт", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                Task { await controller.stopPreview(cameraAddress: cameraAddress) }
                            } label: {
                                Label("Стоп", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    SectionPanel(title: "Apple Watch") {
                        HStack {
                            Label(controller.watchState, systemImage: "applewatch")
                            Spacer()
                            Button {
                                controller.sendStatusToWatch()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Обновить часы")
                        }

                        Text("iPhone держит BLE/Wi-Fi соединение с камерой, а часы получают состояние и подготовлены для кадров preview через WatchConnectivity.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(controller.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("GoPro Screen")
        }
    }
}

private struct PreviewPanel: View {
    @ObservedObject var controller: GoProController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black)
                .aspectRatio(16 / 9, contentMode: .fit)

            VStack(spacing: 10) {
                Image(systemName: controller.isReceivingPreview ? "waveform.path.ecg.rectangle.fill" : "video.slash")
                    .font(.system(size: 38))
                    .foregroundStyle(controller.isReceivingPreview ? .green : .white.opacity(0.72))

                Text(controller.isReceivingPreview ? "Preview stream активен" : "Preview пока не идет")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("\(controller.receivedPacketCount) UDP пакетов")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("UDP MPEG-TS :8554")
                .font(.caption2.monospaced())
                .padding(8)
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct SectionPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DiscoveredCamera: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct GoProWiFiCredentials: Equatable {
    var ssid: String = ""
    var password: String = ""
}

final class GoProController: NSObject, ObservableObject {
    @Published var cameras: [DiscoveredCamera] = []
    @Published var connectedCameraID: UUID?
    @Published var bluetoothState = "Bluetooth запускается"
    @Published var isScanning = false
    @Published var wifiCredentials: GoProWiFiCredentials?
    @Published var statusMessage = "Готово к поиску камеры."
    @Published var watchState = "Сессия не активирована"
    @Published var isReceivingPreview = false
    @Published var receivedPacketCount = 0

    private let goProService = CBUUID(string: "FEA6")
    private let wifiService = CBUUID(string: "B5F90001-AA8D-11E3-9046-0002A5D5C51B")
    private let ssidCharacteristic = CBUUID(string: "B5F90002-AA8D-11E3-9046-0002A5D5C51B")
    private let passwordCharacteristic = CBUUID(string: "B5F90003-AA8D-11E3-9046-0002A5D5C51B")
    private let wifiPowerCharacteristic = CBUUID(string: "B5F90004-AA8D-11E3-9046-0002A5D5C51B")

    private var centralManager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var previewListener: NWListener?
    private let previewQueue = DispatchQueue(label: "GoProScreen.preview")
    private let watchSession: WCSession?

    override init() {
        watchSession = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        watchSession?.delegate = self
        watchSession?.activate()
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Bluetooth недоступен: \(centralManager.state.readableName)."
            return
        }

        cameras.removeAll()
        peripherals.removeAll()
        isScanning = true
        statusMessage = "Ищу GoPro по BLE service FEA6..."
        centralManager.scanForPeripherals(withServices: [goProService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        statusMessage = "Поиск остановлен."
    }

    func connect(to cameraID: UUID) {
        guard let peripheral = peripherals[cameraID] else { return }
        statusMessage = "Подключаюсь к \(peripheral.name ?? "GoPro")..."
        centralManager.connect(peripheral)
    }

    func startPreview(cameraAddress: String) async {
        updateStatus("Запускаю preview stream на GoPro...")
        startPreviewListener()
        await sendGoProCommand(path: "/gopro/camera/stream/start", cameraAddress: cameraAddress)
        sendStatusToWatch()
    }

    func stopPreview(cameraAddress: String) async {
        updateStatus("Останавливаю preview stream...")
        await sendGoProCommand(path: "/gopro/camera/stream/stop", cameraAddress: cameraAddress)
        stopPreviewListener()
        sendStatusToWatch()
    }

    func sendStatusToWatch() {
        let payload: [String: Any] = [
            "camera": currentCameraName,
            "bluetooth": connectedCameraID == nil ? "BLE не подключен" : "BLE подключен",
            "preview": isReceivingPreview ? "Preview активен" : "Preview остановлен",
            "packets": receivedPacketCount,
            "ssid": wifiCredentials?.ssid ?? ""
        ]

        do {
            try watchSession?.updateApplicationContext(payload)
            watchState = watchSession?.isReachable == true ? "Часы рядом" : "Статус отправлен в фон"
        } catch {
            watchState = "Ошибка WatchConnectivity"
            statusMessage = error.localizedDescription
        }
    }

    private var currentCameraName: String {
        guard let connectedCameraID,
              let camera = cameras.first(where: { $0.id == connectedCameraID }) else {
            return "GoPro не выбрана"
        }
        return camera.name
    }

    private func sendGoProCommand(path: String, cameraAddress: String) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = cameraAddress
        components.port = 8080
        components.path = path

        guard let url = components.url else {
            updateStatus("Некорректный адрес камеры.")
            return
        }

        do {
            _ = try await URLSession.shared.data(from: url)
            updateStatus("Команда отправлена: \(path)")
        } catch {
            updateStatus("Не удалось отправить HTTP-команду. Подключите iPhone к Wi-Fi камеры и проверьте IP.")
        }
    }

    private func startPreviewListener() {
        stopPreviewListener()

        do {
            let listener = try NWListener(using: .udp, on: 8554)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.previewQueue ?? .global())
                self?.receivePreviewPackets(from: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.statusMessage = "UDP listener: \(state.readableName)"
                }
            }
            listener.start(queue: previewQueue)
            previewListener = listener
        } catch {
            statusMessage = "Не удалось открыть UDP порт 8554: \(error.localizedDescription)"
        }
    }

    private func stopPreviewListener() {
        previewListener?.cancel()
        previewListener = nil
        isReceivingPreview = false
    }

    private func receivePreviewPackets(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.receivedPacketCount += 1
                    self.isReceivingPreview = true
                    self.statusMessage = "Получаю preview stream от камеры."
                    if self.receivedPacketCount % 30 == 0 {
                        self.sendStatusToWatch()
                    }
                }
            }

            if error == nil {
                self.receivePreviewPackets(from: connection)
            }
        }
    }

    private func updateStatus(_ message: String) {
        statusMessage = message
    }
}

extension GoProController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state.readableName
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "GoPro \(peripheral.identifier.uuidString.prefix(4))"

        peripherals[peripheral.identifier] = peripheral

        if let index = cameras.firstIndex(where: { $0.id == peripheral.identifier }) {
            cameras[index].rssi = RSSI.intValue
            cameras[index].name = name
        } else {
            cameras.append(DiscoveredCamera(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedCameraID = peripheral.identifier
        peripheral.delegate = self
        peripheral.discoverServices([wifiService, goProService])
        statusMessage = "BLE подключен. Читаю Wi-Fi параметры камеры..."
        sendStatusToWatch()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Не удалось подключиться: \(error?.localizedDescription ?? "неизвестная ошибка")."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedCameraID == peripheral.identifier {
            connectedCameraID = nil
        }
        statusMessage = "BLE отключен."
        sendStatusToWatch()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            statusMessage = error?.localizedDescription ?? "Ошибка discovery services."
            return
        }

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            statusMessage = error?.localizedDescription ?? "Ошибка discovery characteristics."
            return
        }

        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == wifiPowerCharacteristic, characteristic.properties.contains(.write) {
                peripheral.writeValue(Data([0x01]), for: characteristic, type: .withResponse)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let text = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""

        if characteristic.uuid == ssidCharacteristic {
            var credentials = wifiCredentials ?? GoProWiFiCredentials()
            credentials.ssid = text
            wifiCredentials = credentials
        }

        if characteristic.uuid == passwordCharacteristic {
            var credentials = wifiCredentials ?? GoProWiFiCredentials()
            credentials.password = text
            wifiCredentials = credentials
        }
    }
}

extension GoProController: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.watchState = error == nil ? "WatchConnectivity активна" : "WatchConnectivity ошибка"
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) { }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

private extension CBManagerState {
    var readableName: String {
        switch self {
        case .unknown: "Bluetooth: неизвестно"
        case .resetting: "Bluetooth перезапускается"
        case .unsupported: "Bluetooth не поддерживается"
        case .unauthorized: "Нет доступа к Bluetooth"
        case .poweredOff: "Bluetooth выключен"
        case .poweredOn: "Bluetooth включен"
        @unknown default: "Bluetooth: новое состояние"
        }
    }
}

private extension NWListener.State {
    var readableName: String {
        switch self {
        case .setup: "настройка"
        case .waiting(let error): "ожидание \(error.localizedDescription)"
        case .ready: "готов, порт 8554"
        case .failed(let error): "ошибка \(error.localizedDescription)"
        case .cancelled: "остановлен"
        @unknown default: "новое состояние"
        }
    }
}

#Preview {
    ContentView()
}
