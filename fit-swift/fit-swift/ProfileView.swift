import SwiftUI

struct ProfileView: View {
    @ObservedObject var profileStore: ProfileStore
    @State private var activeView: ProfileViewTab = .overview

    enum ProfileViewTab: String, CaseIterable {
        case overview = "概览"
        case body = "身体"
        case strategy = "策略"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $activeView) {
                ForEach(ProfileViewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                Group {
                    switch activeView {
                    case .overview:
                        profileOverview
                    case .body:
                        profileBodyForm
                    case .strategy:
                        profileStrategyForm
                    }
                }
                .padding()
            }
        }
        .navigationTitle("个人信息")
    }

    private var profileOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Text(String(profileStore.profile.name.prefix(1)).uppercased())
                            .font(.title)
                            .foregroundStyle(.orange)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileStore.profile.name.isEmpty ? "未设置" : profileStore.profile.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(profileStore.profile.goal) · \(profileStore.profile.trainingLevel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricCard(title: "BMI", value: profileStore.bmi)
                metricCard(title: "BMR", value: "\(profileStore.bmr) kcal")
                metricCard(title: "步数目标", value: "\(profileStore.profile.stepsGoal)")
                metricCard(title: "睡眠目标", value: "\(profileStore.profile.sleepHours) h")
            }
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var profileBodyForm: some View {
        Form {
            Section("基本信息") {
                TextField("姓名", text: $profileStore.profile.name)
                Picker("性别", selection: $profileStore.profile.gender) {
                    Text("男").tag("男")
                    Text("女").tag("女")
                }
                HStack {
                    Text("年龄")
                    Spacer()
                    TextField("", value: $profileStore.profile.age, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("身体数据") {
                HStack {
                    Text("身高 (cm)")
                    Spacer()
                    TextField("", value: $profileStore.profile.heightCm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("体重 (kg)")
                    Spacer()
                    TextField("", value: $profileStore.profile.weightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("体脂 (%)")
                    Spacer()
                    TextField("", value: $profileStore.profile.bodyFat, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("目标体重 (kg)")
                    Spacer()
                    TextField("", value: $profileStore.profile.targetWeightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("伤病/限制") {
                TextField("如无请留空", text: $profileStore.profile.injuries, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
    }

    private var profileStrategyForm: some View {
        Form {
            Section("训练策略") {
                Picker("训练水平", selection: $profileStore.profile.trainingLevel) {
                    Text("初级").tag("初级")
                    Text("中级").tag("中级")
                    Text("高级").tag("高级")
                }
                TextField("核心目标", text: $profileStore.profile.goal)
                Stepper("每周训练天数: \(profileStore.profile.weeklyTrainingDays)", value: $profileStore.profile.weeklyTrainingDays, in: 1...7)
            }
            Section("生活习惯") {
                HStack {
                    Text("睡眠目标 (h)")
                    Spacer()
                    TextField("", value: $profileStore.profile.sleepHours, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("步数目标")
                    Spacer()
                    TextField("", value: $profileStore.profile.stepsGoal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}
