//
//  ContentView.swift
//  GoProScreen Watch App
//
//  Created by Ruslan Sirazhetdinov on 2026-10-01.
//

import Combine
import CoreBluetooth
import ImageIO
import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchGoProModel()
    @State private var cameraAddress = "10.5.5.9"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black)
                        .frame(height: 108)

                    if let previewImage = model.previewImage {
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: model.isPreviewCommandActive ? "video.fill" : "applewatch.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(model.isPreviewCommandActive ? .green : .white.opacity(0.76))

                            Text(model.connectionTitle)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            Text(model.status)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                    }
                }

                HStack {
                    Button {
                        model.toggleScanning()
                    } label: {
                        Label(model.isScanning ? "Стоп" : "Поиск", systemImage: model.isScanning ? "stop.fill" : "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.disconnect()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Отключиться")
                }

                if model.cameras.isEmpty {
                    Text("Включите pairing на GoPro. Часы ищут BLE service FEA6.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.cameras) { camera in
                        Button {
                            model.connect(to: camera.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(camera.name)
                                        .font(.caption)
                                    Text("RSSI \(camera.rssi)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: camera.id == model.connectedCameraID ? "checkmark.circle.fill" : "chevron.right")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                StatusRow(title: "BLE", value: model.bluetooth, symbol: "dot.radiowaves.left.and.right")

                if !model.ssid.isEmpty {
                    StatusRow(title: "Wi-Fi", value: model.ssid, symbol: "wifi")
                }

                TextField("IP", text: $cameraAddress)
                    .textInputAutocapitalization(.never)

                Button {
                    Task { await model.testCameraHTTP(cameraAddress: cameraAddress) }
                } label: {
                    Label("Тест HTTP", systemImage: "network")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await model.loadLatestFrame(cameraAddress: cameraAddress) }
                } label: {
                    Label("Кадр", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                Button {
                    model.toggleAutoFrames(cameraAddress: cameraAddress)
                } label: {
                    Label(model.isAutoFrameRunning ? "Стоп авто" : "Автокадр", systemImage: model.isAutoFrameRunning ? "pause.fill" : "camera.aperture")
                }
                .buttonStyle(.borderedProminent)

                Text("Автокадр делает реальные фото и обновляет preview через HTTP. Это расходует батарею и заполняет карту памяти.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }
}

struct WatchDiscoveredCamera: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

final class WatchGoProModel: NSObject, ObservableObject {
    @Published var cameras: [WatchDiscoveredCamera] = []
    @Published var connectedCameraID: UUID?
    @Published var bluetooth = "Bluetooth запускается"
    @Published var isScanning = false
    @Published var ssid = ""
    @Published var password = ""
    @Published var status = "Телефон не нужен"
    @Published var isPreviewCommandActive = false
    @Published var previewImage: CGImage?
    @Published var isAutoFrameRunning = false
    @Published var isBusy = false

    var connectionTitle: String {
        if connectedCameraID != nil {
            return "GoPro подключена"
        }
        if isScanning {
            return "Ищу GoPro"
        }
        return "Watch only"
    }

    private let goProService = CBUUID(string: "FEA6")
    private let wifiService = CBUUID(string: "B5F90001-AA8D-11E3-9046-0002A5D5C51B")
    private let ssidCharacteristic = CBUUID(string: "B5F90002-AA8D-11E3-9046-0002A5D5C51B")
    private let passwordCharacteristic = CBUUID(string: "B5F90003-AA8D-11E3-9046-0002A5D5C51B")
    private let wifiPowerCharacteristic = CBUUID(string: "B5F90004-AA8D-11E3-9046-0002A5D5C51B")

    private var centralManager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var autoFrameTask: Task<Void, Never>?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    deinit {
        autoFrameTask?.cancel()
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            status = centralManager.state.readableName
            return
        }

        cameras.removeAll()
        peripherals.removeAll()
        isScanning = true
        status = "Ищу BLE service FEA6..."
        centralManager.scanForPeripherals(withServices: [goProService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        status = "Поиск остановлен"
    }

    func connect(to cameraID: UUID) {
        guard let peripheral = peripherals[cameraID] else { return }
        status = "Подключаюсь..."
        centralManager.connect(peripheral)
    }

    func disconnect() {
        guard let connectedCameraID,
              let peripheral = peripherals[connectedCameraID] else {
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func testCameraHTTP(cameraAddress: String) async {
        await sendGoProCommand(path: "/gopro/camera/state", cameraAddress: cameraAddress)
    }

    func toggleAutoFrames(cameraAddress: String) {
        if isAutoFrameRunning {
            stopAutoFrames()
        } else {
            startAutoFrames(cameraAddress: cameraAddress)
        }
    }

    func startAutoFrames(cameraAddress: String) {
        autoFrameTask?.cancel()
        isAutoFrameRunning = true
        status = "Автокадр запущен"

        autoFrameTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureAndLoadFrame(cameraAddress: cameraAddress)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopAutoFrames() {
        autoFrameTask?.cancel()
        autoFrameTask = nil
        isAutoFrameRunning = false
        status = "Автокадр остановлен"
    }

    func captureAndLoadFrame(cameraAddress: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        status = "Снимаю кадр..."

        do {
            _ = try await data(from: "/gopro/camera/presets/set_group?id=1001", cameraAddress: cameraAddress)
            try? await Task.sleep(for: .seconds(1))
            _ = try await data(from: "/gopro/camera/shutter/start", cameraAddress: cameraAddress)
            try? await Task.sleep(for: .seconds(2))
            try await loadLatestFrameInternal(cameraAddress: cameraAddress)
        } catch {
            status = networkErrorMessage(for: error)
        }
    }

    func loadLatestFrame(cameraAddress: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await loadLatestFrameInternal(cameraAddress: cameraAddress)
        } catch {
            status = networkErrorMessage(for: error)
        }
    }

    private func loadLatestFrameInternal(cameraAddress: String) async throws {
        status = "Ищу последний кадр..."

        let media = try await fetchLatestMedia(cameraAddress: cameraAddress, preferJPEG: true)
        let imageData = try await fetchPreviewImageData(for: media, cameraAddress: cameraAddress)

        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            status = "Камера вернула не JPEG"
            return
        }

        previewImage = cgImage
        status = "Кадр: \(media.fileName)"
    }

    private func sendGoProCommand(path: String, cameraAddress: String) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = cameraAddress
        components.port = 8080
        components.path = path

        guard let url = components.url else {
            status = "Неверный IP"
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                status = "HTTP \(httpResponse.statusCode): \(path)"
            } else {
                status = "Ответ без HTTP статуса"
            }
        } catch {
            status = networkErrorMessage(for: error)
        }
    }

    private func fetchLatestMedia(cameraAddress: String, preferJPEG: Bool) async throws -> GoProMediaFile {
        let data = try await data(from: "/gopro/media/list", cameraAddress: cameraAddress)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let directories = json?["media"] as? [[String: Any]] ?? []
        var files: [GoProMediaFile] = []

        for directory in directories {
            let directoryName = directory["d"] as? String ?? ""
            let directoryFiles = directory["fs"] as? [[String: Any]] ?? []

            for file in directoryFiles {
                let fileName = file["n"] as? String ?? ""
                let modified = Self.mediaTimestamp(from: file["mod"]) ?? Self.mediaTimestamp(from: file["cre"]) ?? 0

                if !fileName.isEmpty {
                    files.append(GoProMediaFile(directory: directoryName, fileName: fileName, modified: modified))
                }
            }
        }

        let candidates = preferJPEG ? files.filter(\.isJPEG) : files
        let sortableFiles = candidates.isEmpty ? files : candidates

        guard let latest = sortableFiles.sorted(by: { lhs, rhs in
            if lhs.modified != rhs.modified {
                return lhs.modified > rhs.modified
            }
            return lhs.captureOrder > rhs.captureOrder
        }).first else {
            throw GoProWatchError.noMedia
        }

        return latest
    }

    private static func mediaTimestamp(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }

        if let string = value as? String {
            return Int(string)
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func fetchPreviewImageData(for media: GoProMediaFile, cameraAddress: String) async throws -> Data {
        let encodedPath = "\(media.directory)/\(media.fileName)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(media.directory)/\(media.fileName)"

        let previewPaths = [
            "/gopro/media/screennail?path=\(encodedPath)",
            "/gopro/media/thumbnail?path=\(encodedPath)"
        ]

        for path in previewPaths {
            do {
                return try await data(from: path, cameraAddress: cameraAddress)
            } catch {
                continue
            }
        }

        if media.isJPEG {
            return try await data(from: "/videos/DCIM/\(media.directory)/\(media.fileName)", cameraAddress: cameraAddress, timeout: 8, maximumBytes: 1_200_000)
        }

        throw GoProWatchError.noPreviewImage
    }

    private func data(from path: String, cameraAddress: String, timeout: TimeInterval = 12, maximumBytes: Int? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = cameraAddress
        components.port = 8080
        components.path = path.components(separatedBy: "?").first ?? path

        if let query = path.components(separatedBy: "?").dropFirst().first {
            components.percentEncodedQuery = query
        }

        guard let url = components.url else {
            throw GoProWatchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GoProWatchError.badHTTPStatus
        }

        if let maximumBytes, data.count > maximumBytes {
            throw GoProWatchError.responseTooLarge
        }

        return data
    }

    private func networkErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "Timeout: часы не достучались до 10.5.5.9"
            case NSURLErrorCannotConnectToHost:
                return "Нет TCP: порт 8080 недоступен"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "Нет маршрута: проверьте Wi-Fi часов"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "ATS блокирует HTTP"
            default:
                return "URL error \(nsError.code): \(nsError.localizedDescription)"
            }
        }

        return nsError.localizedDescription
    }
}

private struct GoProMediaFile {
    let directory: String
    let fileName: String
    let modified: Int

    var isJPEG: Bool {
        let lowercasedName = fileName.lowercased()
        return lowercasedName.hasSuffix(".jpg") || lowercasedName.hasSuffix(".jpeg")
    }

    var captureOrder: Int {
        let digits = fileName.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

private enum GoProWatchError: LocalizedError {
    case invalidURL
    case badHTTPStatus
    case noMedia
    case noPreviewImage
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Неверный URL"
        case .badHTTPStatus:
            "GoPro вернула ошибку HTTP"
        case .noMedia:
            "На карте нет медиа"
        case .noPreviewImage:
            "Не удалось получить thumbnail"
        case .responseTooLarge:
            "Файл слишком большой для часов"
        }
    }
}

extension WatchGoProModel: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetooth = central.state.readableName
        status = central.state == .poweredOn ? "Можно искать камеру" : central.state.readableName
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "GoPro \(peripheral.identifier.uuidString.prefix(4))"

        peripherals[peripheral.identifier] = peripheral

        if let index = cameras.firstIndex(where: { $0.id == peripheral.identifier }) {
            cameras[index].name = name
            cameras[index].rssi = RSSI.intValue
        } else {
            cameras.append(WatchDiscoveredCamera(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedCameraID = peripheral.identifier
        isScanning = false
        peripheral.delegate = self
        peripheral.discoverServices([wifiService, goProService])
        status = "BLE подключен"
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "BLE ошибка подключения"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedCameraID == peripheral.identifier {
            connectedCameraID = nil
        }
        status = "BLE отключен"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            status = "Ошибка services"
            return
        }

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            status = "Ошибка characteristics"
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
            ssid = text
        }

        if characteristic.uuid == passwordCharacteristic {
            password = text
        }
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

#Preview {
    ContentView()
}
