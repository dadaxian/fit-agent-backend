import Foundation

/// 用户档案（与 fitter profile 结构对齐，存 UserDefaults）
struct UserProfile: Codable {
    var name: String
    var gender: String
    var age: Int
    var heightCm: Double
    var weightKg: Double
    var bodyFat: Double
    var trainingLevel: String
    var goal: String
    var targetWeightKg: Double
    var weeklyTrainingDays: Int
    var injuries: String
    var sleepHours: Double
    var stepsGoal: Int

    static let defaultProfile = UserProfile(
        name: "",
        gender: "男",
        age: 28,
        heightCm: 170,
        weightKg: 65,
        bodyFat: 20,
        trainingLevel: "中级",
        goal: "增肌 + 体态优化",
        targetWeightKg: 70,
        weeklyTrainingDays: 4,
        injuries: "",
        sleepHours: 7,
        stepsGoal: 8000
    )
}

final class ProfileStore: ObservableObject {
    static let key = "fit-swift-profile"

    @Published var profile: UserProfile {
        didSet {
            if let data = try? JSONEncoder().encode(profile) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = p
        } else {
            profile = .defaultProfile
        }
    }

    var bmi: String {
        let h = profile.heightCm / 100
        guard h > 0 else { return "-" }
        return String(format: "%.1f", profile.weightKg / (h * h))
    }

    var bmr: Int {
        let w = profile.weightKg
        let h = profile.heightCm
        let a = Double(profile.age)
        if profile.gender == "女" {
            return Int(10 * w + 6.25 * h - 5 * a - 161)
        }
        return Int(10 * w + 6.25 * h - 5 * a + 5)
    }
}
