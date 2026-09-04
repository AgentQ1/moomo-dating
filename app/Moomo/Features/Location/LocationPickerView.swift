import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - Model

/// Drives the location picker: the map's camera, the city under the pin, and
/// city search.
///
/// Coordinates live here only as camera state. Nothing this model publishes for
/// saving is finer-grained than a `CityLocation`, and `onSave` is handed a city
/// — see `CityLocationResolver` for why that boundary matters.
@MainActor
final class LocationPickerModel: ObservableObject {

    /// A broad view of North America, used before we know anything better.
    private static let fallbackRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 42)
    )

    /// Roughly city-sized. Wide enough that panning moves between
    /// neighbourhoods rather than houses.
    private static let citySpan = MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28)

    @Published var camera: MapCameraPosition = .region(fallbackRegion)
    @Published var query: String = ""

    /// The city under the pin — what Save will store.
    @Published private(set) var pinned: CityLocation?
    @Published private(set) var isResolving = false
    @Published private(set) var results: [CityLocation] = []
    @Published private(set) var isSearching = false
    /// Shown when the device's own location can't be used.
    @Published private(set) var locationNotice: String?

    let locator = CurrentCityLocator()

    private let initial: CityLocation?
    private var resolveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Where the camera was the last time we accepted it. Laying the map out
    /// and recentring it in code both fire the same callback a drag does, and
    /// neither is the user choosing a city: the first settle only establishes
    /// this baseline, and `recentre` moves it forward itself.
    private var lastAcceptedCentre: CLLocationCoordinate2D?

    init(current: CityLocation?) {
        initial = current
        pinned = current
    }

    var canSave: Bool { pinned != nil && !isResolving }

    /// Opens on the current city when there is one, so the first thing the map
    /// shows is the answer already on file.
    func start() async {
        guard let initial, let centre = await CityLocationResolver.centre(of: initial) else { return }
        recentre(on: centre)
    }

    // MARK: - Map

    /// The map stopped moving. Whatever is under the pin is the new answer.
    func mapSettled(at centre: CLLocationCoordinate2D) {
        let previous = lastAcceptedCentre
        lastAcceptedCentre = centre
        // Nothing to compare against yet, or the map came to rest where we
        // put it — either way the user has not chosen anything.
        guard let previous, !Self.isSamePlace(previous, centre) else { return }

        resolveTask?.cancel()
        isResolving = true
        resolveTask = Task { [weak self] in
            let city = await CityLocationResolver.city(at: centre)
            guard !Task.isCancelled, let self else { return }
            isResolving = false
            // A coordinate the geocoder can't name a city for (open water, a
            // gap in its data) leaves the last good answer standing rather
            // than blanking the sheet.
            if let city { pinned = city }
        }
    }

    // MARK: - Search

    func queryChanged() {
        searchTask?.cancel()
        let text = query
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            // Typing shouldn't fire a search per keystroke.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await CityLocationResolver.search(text)
            guard !Task.isCancelled, let self else { return }
            results = found
            isSearching = false
        }
    }

    func choose(_ city: CityLocation) {
        pinned = city
        query = ""
        results = []
        searchTask?.cancel()
        Task { [weak self] in
            guard let centre = await CityLocationResolver.centre(of: city) else { return }
            self?.recentre(on: centre)
        }
    }

    // MARK: - Current location

    func useCurrentLocation() async {
        locationNotice = nil
        isResolving = true
        defer { isResolving = false }

        do {
            let city = try await locator.currentCity()
            pinned = city
            // Deliberately recentred on the *city*, not on the device: the map
            // should never draw a marker over where the user is standing.
            if let centre = await CityLocationResolver.centre(of: city) {
                recentre(on: centre)
            }
        } catch CurrentCityLocator.Failure.denied {
            locationNotice = "Location access is off. Turn it on in Settings, or search for your city."
        } catch {
            locationNotice = "We couldn't work out your city. Try searching for it."
        }
    }

    // MARK: - Camera

    private func recentre(on centre: CLLocationCoordinate2D) {
        lastAcceptedCentre = centre
        resolveTask?.cancel()
        isResolving = false
        withAnimation(Motion.transition) {
            camera = .region(MKCoordinateRegion(center: centre, span: Self.citySpan))
        }
    }

    /// Close enough that no city could have changed — about 100 metres. Guards
    /// against the sub-degree jitter a settling camera reports.
    private static func isSamePlace(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.001 && abs(lhs.longitude - rhs.longitude) < 0.001
    }
}

// MARK: - View

/// City picker: search, or move the map under the pin.
///
/// Only the resolved city reaches the PROFILE. The map is a way of *naming* a
/// city, not a way of recording where someone is — `Profile.location` has
/// nowhere to put a coordinate and is not going to grow one.
///
/// The separate coarse position that powers proximity ranking is not written
/// here and is never part of a profile: see `CoarseLocationReporter`, which
/// stores a ~1 km-rounded point in the owner-only
/// `users/{uid}/private/location`. Nothing on this screen publishes a
/// coordinate to anyone.
struct LocationPickerView: View {
    @StateObject private var model: LocationPickerModel
    @Environment(\.dismiss) private var dismiss

    private let onSave: (CityLocation) -> Void

    init(current: CityLocation?, onSave: @escaping (CityLocation) -> Void) {
        _model = StateObject(wrappedValue: LocationPickerModel(current: current))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.sm) {
                searchField

                ZStack {
                    if model.results.isEmpty && !model.isSearching {
                        mapArea
                    } else {
                        resultsList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
            .padding(.top, Space.sm)
            .background(Palette.canvas)
            .navigationTitle("Your city")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("location.cancel")
                }
            }
            .task { await model.start() }
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        // No identifier: `MoomoTextField` surfaces to XCUITest under its
        // placeholder, the way every other field in the app is matched.
        MoomoTextField(placeholder: "Search for a city", text: $model.query, characterLimit: nil)
            .padding(.horizontal, Space.gutter)
            .onChange(of: model.query) { _, _ in model.queryChanged() }
    }

    private var mapArea: some View {
        Map(position: $model.camera, interactionModes: [.pan, .zoom])
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { context in
                model.mapSettled(at: context.region.center)
            }
            .overlay { centrePin }
            .overlay(alignment: .topTrailing) { currentLocationButton }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.horizontal, Space.gutter)
            .accessibilityIdentifier("location.map")
            .accessibilityLabel("Map. Move it to choose a city.")
    }

    /// Fixed to the centre of the map: the map moves under it, which is what
    /// makes it "draggable" without the pin ever needing a gesture of its own.
    private var centrePin: some View {
        MapPinShape()
            .fill(Palette.magenta)
            .overlay(alignment: .top) {
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .padding(.top, 8)
            }
            .frame(width: 28, height: 36)
            .shadow(color: Palette.ink.opacity(0.25), radius: 6, y: 3)
            // The tip, not the middle, marks the spot.
            .offset(y: -18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var currentLocationButton: some View {
        Button {
            Task { await model.useCurrentLocation() }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.blue)
                .frame(width: Size.minTapTarget, height: Size.minTapTarget)
                .background(Circle().fill(Palette.surface))
                .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .padding(Space.sm)
        .accessibilityLabel("Use my current location")
        .accessibilityIdentifier("location.useCurrent")
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: Space.xs) {
                if model.isSearching && model.results.isEmpty {
                    ProgressView()
                        .padding(.top, Space.xl)
                }
                ForEach(model.results, id: \.display) { city in
                    SelectableCard(
                        title: city.compactDisplay,
                        isSelected: model.pinned == city
                    ) {
                        // Picking a city ends the search, so the keyboard has
                        // no business staying over the Save button.
                        dismissKeyboard()
                        model.choose(city)
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private var footer: some View {
        VStack(spacing: Space.xs) {
            if let notice = model.locationNotice {
                Text(notice)
                    .font(Typography.body)
                    .foregroundStyle(Palette.coral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                "Other people only ever see your city. Baybe keeps a rounded "
                    + "area of about a kilometre, privately, to show you people "
                    + "who are closer to you.",
                systemImage: "lock.shield.fill"
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(
                title: saveTitle,
                isEnabled: model.canSave,
                isLoading: model.isResolving
            ) {
                guard let city = model.pinned else { return }
                onSave(city)
                dismiss()
            }
            .accessibilityIdentifier("location.save")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.md)
    }

    private var saveTitle: String {
        guard let pinned = model.pinned else { return "Pick a city" }
        return "Use \(pinned.compactDisplay)"
    }
}

#Preview {
    LocationPickerView(current: CityCatalog.cities[1]) { _ in }
}
