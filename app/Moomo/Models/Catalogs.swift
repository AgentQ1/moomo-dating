import Foundation

/// The interest chips offered everywhere interests are edited (onboarding,
/// profile editing). One list, so a profile can never hold an interest the
/// editor can't render.
enum InterestCatalog {
    static let options = [
        "Coffee", "Photography", "Hiking", "Cooking", "Live music", "Films",
        "Reading", "Travel", "Gaming", "Fitness", "Art", "Football",
        "Dogs", "Cats", "Dancing", "Comedy", "Tech", "Fashion"
    ]
}

/// The supported cities. A short, explicit list — coarse location via
/// CoreLocation is wired in later, and even then it will only ever resolve to
/// a city, never coordinates (see `CityLocation`).
enum CityCatalog {
    static let cities: [CityLocation] = [
        CityLocation(city: "New York", region: "NY", countryCode: "US"),
        CityLocation(city: "Chicago", region: "IL", countryCode: "US"),
        CityLocation(city: "San Francisco", region: "CA", countryCode: "US"),
        CityLocation(city: "Los Angeles", region: "CA", countryCode: "US"),
        CityLocation(city: "London", region: nil, countryCode: "GB"),
        CityLocation(city: "Toronto", region: "ON", countryCode: "CA")
    ]
}
