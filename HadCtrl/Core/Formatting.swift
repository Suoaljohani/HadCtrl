import Foundation

/// Dates are shown in hospital time regardless of the device zone (spec §07, §15).
enum HCFormat {
    static func date(_ date: Date, calendar: HospitalCalendar = .riyadh) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func dateTime(_ date: Date, calendar: HospitalCalendar = .riyadh) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func relative(_ date: Date, now: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

extension TaskStatus {
    var title: String {
        switch self {
        case .draft: return String(localized: "مسودة")
        case .assigned: return String(localized: "مسندة")
        case .acknowledged: return String(localized: "مستلمة")
        case .inProgress: return String(localized: "قيد التنفيذ")
        case .blocked: return String(localized: "متعثرة بعائق")
        case .submitted: return String(localized: "مرفوعة للاعتماد")
        case .returned: return String(localized: "معادة للاستكمال")
        case .completed: return String(localized: "مكتملة")
        case .cancelled: return String(localized: "ملغاة")
        }
    }

    var tone: StatusTone {
        switch self {
        case .completed: return .good
        case .blocked, .returned: return .warning
        case .cancelled, .draft: return .neutral
        default: return .info
        }
    }
}

extension TaskTransition {
    var title: String {
        switch self {
        case .assign: return String(localized: "إسناد")
        case .acknowledge: return String(localized: "تأكيد الاستلام")
        case .start: return String(localized: "بدء التنفيذ")
        case .block: return String(localized: "تسجيل عائق")
        case .unblock: return String(localized: "استئناف")
        case .submit: return String(localized: "رفع الإنجاز")
        case .approve: return String(localized: "اعتماد")
        case .return: return String(localized: "إعادة للاستكمال")
        case .cancel: return String(localized: "إلغاء المهمة")
        case .reassign: return String(localized: "إعادة إسناد")
        }
    }
}

extension Priority {
    var title: String {
        switch self {
        case .low: return String(localized: "منخفضة")
        case .normal: return String(localized: "عادية")
        case .high: return String(localized: "عالية")
        case .urgent: return String(localized: "عاجلة")
        }
    }
}

extension ReportStatus {
    var title: String {
        switch self {
        case .notSubmitted: return String(localized: "لم يُسلّم")
        case .submitted: return String(localized: "مُسلّم")
        case .underReview: return String(localized: "بانتظار المراجعة")
        case .returned: return String(localized: "معاد للاستكمال")
        case .approved: return String(localized: "معتمد")
        case .waived: return String(localized: "معفى")
        }
    }

    var tone: StatusTone {
        switch self {
        case .approved: return .good
        case .returned, .notSubmitted: return .warning
        case .waived: return .neutral
        default: return .info
        }
    }
}

extension DashboardReading.Metric {
    var title: String {
        switch self {
        case .goalsAchieved: return String(localized: "المستهدفات المحققة")
        case .indicatorsUpdated: return String(localized: "المؤشرات المحدّثة")
        case .reportsReceived: return String(localized: "التقارير المستلمة")
        case .tasksCompleted: return String(localized: "المهام المكتملة")
        case .achievementsApproved: return String(localized: "المنجزات المعتمدة")
        case .awaitingDirector: return String(localized: "بانتظار اعتمادك")
        }
    }
}

extension CoverageResult.Verdict {
    var title: String {
        switch self {
        case .insufficientData: return String(localized: "بيانات غير كافية للحكم")
        case .provisional: return String(localized: "حكم مؤقت")
        case .final: return String(localized: "نتيجة نهائية")
        case .completeButOpen: return String(localized: "مكتملة والفترة مفتوحة")
        }
    }

    var tone: StatusTone {
        switch self {
        case .insufficientData: return .neutral
        case .provisional, .completeButOpen: return .warning
        case .final: return .good
        }
    }
}
