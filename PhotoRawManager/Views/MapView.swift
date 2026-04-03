import SwiftUI
import MapKit

// MARK: - Photo Map View

struct PhotoMapView: View {
    let photos: [PhotoItem]
    let onSelectPhoto: (UUID) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
        span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
    )

    private var gpsPhotos: [PhotoItem] {
        photos.filter { $0.exifData?.hasGPS == true }
    }

    private var annotations: [PhotoAnnotation] {
        gpsPhotos.compactMap { photo in
            guard let lat = photo.exifData?.latitude,
                  let lon = photo.exifData?.longitude else { return nil }
            return PhotoAnnotation(
                id: photo.id,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                title: photo.fileName
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "map.fill")
                    .foregroundColor(.accentColor)
                Text("GPS 지도")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Text("GPS 사진: \(gpsPhotos.count)장 / 전체: \(photos.count)장")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if gpsPhotos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("GPS 정보가 있는 사진이 없습니다")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoMapRepresentable(
                    annotations: annotations,
                    region: $region,
                    onSelectAnnotation: { annotationID in
                        onSelectPhoto(annotationID)
                    }
                )
                .onAppear { fitRegion() }
            }
        }
        .frame(minWidth: 600, minHeight: 450)
    }

    private func fitRegion() {
        guard !gpsPhotos.isEmpty else { return }
        let lats = gpsPhotos.compactMap { $0.exifData?.latitude }
        let lons = gpsPhotos.compactMap { $0.exifData?.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max(0.01, (maxLat - minLat) * 1.3)
        let spanLon = max(0.01, (maxLon - minLon) * 1.3)

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }
}

// MARK: - Annotation Model

struct PhotoAnnotation: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String
}

// MARK: - MKMapView Representable

struct PhotoMapRepresentable: NSViewRepresentable {
    let annotations: [PhotoAnnotation]
    @Binding var region: MKCoordinateRegion
    let onSelectAnnotation: (UUID) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Remove old annotations
        mapView.removeAnnotations(mapView.annotations)

        // Add new ones
        let mkAnnotations = annotations.map { ann -> MKPhotoAnnotation in
            let mk = MKPhotoAnnotation(photoID: ann.id)
            mk.coordinate = ann.coordinate
            mk.title = ann.title
            return mk
        }
        mapView.addAnnotations(mkAnnotations)
        mapView.setRegion(region, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelectAnnotation)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        let onSelect: (UUID) -> Void

        init(onSelect: @escaping (UUID) -> Void) {
            self.onSelect = onSelect
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let photoAnn = annotation as? MKPhotoAnnotation else { return nil }
            let identifier = "PhotoPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: photoAnn, reuseIdentifier: identifier)
            view.annotation = photoAnn
            view.canShowCallout = true
            view.markerTintColor = .systemBlue
            view.glyphImage = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let photoAnn = view.annotation as? MKPhotoAnnotation else { return }
            onSelect(photoAnn.photoID)
        }
    }
}

// MARK: - Custom MKAnnotation

class MKPhotoAnnotation: NSObject, MKAnnotation {
    let photoID: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(photoID: UUID) {
        self.photoID = photoID
        self.coordinate = CLLocationCoordinate2D()
        super.init()
    }
}
