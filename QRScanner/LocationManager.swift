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

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    /// 最近一次反解析得到的地址文字（如水印开关关闭或未定位则为 nil）
    @Published private(set) var currentAddress: String?

    private let manager: CLLocationManager
    private var lastGeocodeTime: Date?

    private override init() {
        self.manager = CLLocationManager()
        
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
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        // 节流：60 秒内位置变化不重复地理编码
        if let last = lastGeocodeTime, Date().timeIntervalSince(last) < 60 { return }
        lastGeocodeTime = Date()

        // 统一使用 CLGeocoder（iOS 17 起就支持，且在 iOS 26 上依然可用）。
        // 原先的 MKReverseGeocodingRequest 是 iOS 26 新增 API，用 iOS 18 SDK（Xcode 16.x）编译时
        // 该符号根本不存在，#available 也无法兜底，会导致真机构建直接失败。
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self else { return }
            if let error = error {
                print("逆地理失败: \(error.localizedDescription)")
                return
            }
            guard let placemark = placemarks?.first else { return }
            let address = self.formatAddress(placemark)
            DispatchQueue.main.async {
                self.currentAddress = address
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("定位失败: \(error.localizedDescription)")
    }

    // MARK: CLPlacemark 地址格式化
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
}
