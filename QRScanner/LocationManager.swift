//
//  LocationManager.swift
//  QRScanner
//
//  功能: 获取当前位置并反解析为地址文字，供拍照水印使用。
//  说明: 首次使用会请求"使用期间"定位权限；地理编码结果做 60 秒节流，避免频繁请求。
//

import Foundation
import CoreLocation
import Combine
import MapKit

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    /// 最近一次反解析得到的地址文字（如水印开关关闭或未定位则为 nil）
    @Published private(set) var currentAddress: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager: CLLocationManager
    private var lastGeocodeTime: Date?

    private override init() {
        self.manager = CLLocationManager()
        self.authorizationStatus = manager.authorizationStatus
        
        super.init()
        
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// 开始定位（已授权则直接更新，未授权则弹出系统授权请求）
    func startUpdating() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse
                    || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        // 节流：60 秒内位置变化不重复地理编码
        if let last = lastGeocodeTime, Date().timeIntervalSince(last) < 60 { return }
        lastGeocodeTime = Date()

        if #available(iOS 26.0, *) {
            Task {
                await reverseGeocode(location: location)
            }
        } else {
            // iOS <26 旧CLGeocoder
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
                guard let self = self, let placemark = placemarks?.first else { return }
                let address = self.formatAddress(placemark)
                DispatchQueue.main.async {
                    self.currentAddress = address
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("定位失败: \(error.localizedDescription)")
    }

    // MARK: iOS <26 CLPlacemark 格式化
    private func formatAddress(_ placemark: CLPlacemark) -> String {
        var parts: [String] = []
        if let name = placemark.name {
            parts.append(name)
        }
        if let thoroughfare = placemark.thoroughfare, placemark.name != thoroughfare {
            parts.append(thoroughfare)
        }
        if let locality = placemark.locality, !parts.contains(locality) {
            parts.append(locality)
        }
        return parts.joined(separator: " ")
    }

    // MARK: iOS26+ MKReverseGeocodingRequest，不再使用placemark
    @available(iOS 26.0, *)
    private func reverseGeocode(location: CLLocation) async {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            print("逆地理请求创建失败")
            return
        }
        do {
            let mapItems = try await request.mapItems
            guard let mapItem = mapItems.first else { return }
            
            // ✅ 直接用 MKAddress shortAddress，水印简洁地址首选
            var addressText: String?
            if let shortAddr = mapItem.address?.shortAddress, !shortAddr.isEmpty {
                addressText = shortAddr
            } else if let representations = mapItem.addressRepresentations {
                // fallback：addressRepresentations.fullAddress 单行
                addressText = representations.fullAddress(includingRegion: false, singleLine: true)
            }
            
            guard let finalAddr = addressText else { return }
            DispatchQueue.main.async {
                self.currentAddress = finalAddr
            }
        } catch {
            print("逆地理失败: \(error.localizedDescription)")
        }
    }
}
