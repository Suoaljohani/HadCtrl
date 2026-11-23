import Foundation

/// Machine-readable server/client error codes (spec §27). The app never parses
/// human error text to decide whether to retry or re-authenticate.
enum HCErrorCode: String, Sendable, Codable, CaseIterable {
    case authRequired = "HC_AUTH_REQUIRED"
    case membershipInactive = "HC_MEMBERSHIP_INACTIVE"
    case forbidden = "HC_FORBIDDEN"
    case notFound = "HC_NOT_FOUND"
    case validationFailed = "HC_VALIDATION_FAILED"
    case versionConflict = "HC_VERSION_CONFLICT"
    case periodFrozen = "HC_PERIOD_FROZEN"
    case idempotencyMismatch = "HC_IDEMPOTENCY_MISMATCH"
    case attachmentIncomplete = "HC_ATTACHMENT_INCOMPLETE"
    case rateLimited = "HC_RATE_LIMITED"
    case serverError = "HC_SERVER_ERROR"
}

/// App-wide error model. `userMessage` is safe to show; diagnostics stay separate.
enum AppError: Error, Equatable, Sendable {
    case network(offline: Bool)
    case server(code: HCErrorCode, fieldErrors: [String: String], currentVersion: Int?, correlationID: String?)
    case configuration(String)
    case decoding(String)
    case file(String)
    case cancelled

    var code: HCErrorCode? {
        if case .server(let code, _, _, _) = self { return code }
        return nil
    }

    /// Whether repeating the same request (same request_id) is safe and useful.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .server(let code, _, _, _): return code == .rateLimited || code == .serverError
        default: return false
        }
    }

    var requiresSignIn: Bool { code == .authRequired }

    var userMessage: String {
        switch self {
        case .network(let offline):
            return offline ? String(localized: "لا يوجد اتصال بالإنترنت. تُعرض آخر بيانات محفوظة إن وجدت.")
                           : String(localized: "تعذر الاتصال بالخادم. حاول مرة أخرى.")
        case .server(let code, _, _, _):
            switch code {
            case .authRequired: return String(localized: "انتهت الجلسة. سجّل الدخول مرة أخرى.")
            case .membershipInactive: return String(localized: "عضويتك غير نشطة. تواصل مع إدارة النظام.")
            case .forbidden: return String(localized: "لا تملك صلاحية تنفيذ هذا الإجراء.")
            case .notFound: return String(localized: "السجل غير موجود أو لم يعد متاحًا لك.")
            case .validationFailed: return String(localized: "راجع الحقول المظللة.")
            case .versionConflict: return String(localized: "عدّل شخص آخر هذا السجل. راجع النسخة الأحدث قبل الحفظ.")
            case .periodFrozen: return String(localized: "الفترة مجمّدة ولا تقبل التعديل.")
            case .idempotencyMismatch: return String(localized: "تعارض في معرف الطلب. أعد المحاولة كطلب جديد.")
            case .attachmentIncomplete: return String(localized: "لم يكتمل رفع مرفق إلزامي.")
            case .rateLimited: return String(localized: "طلبات كثيرة. انتظر قليلًا ثم حاول مجددًا.")
            case .serverError: return String(localized: "حدث خطأ في الخادم. حاول لاحقًا.")
            }
        case .configuration:
            return String(localized: "إعداد الاتصال بالخادم غير مكتمل في هذا الإصدار.")
        case .decoding:
            return String(localized: "تعذر قراءة استجابة الخادم.")
        case .file:
            return String(localized: "تعذر معالجة الملف.")
        case .cancelled:
            return String(localized: "أُلغي الطلب.")
        }
    }
}
