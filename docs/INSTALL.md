# تثبيت تطبيق قيادة (HadCtrl) على الآيفون

يوجد مساران. لا يُثبَّت أي ملف IPA على الآيفون بمجرد تنزيله وفتحه؛ يلزم توقيع Apple مطابق للجهاز.

---

## المسار ١ — نسخة غير موقّعة + توقيعها بحساب Apple الخاص بك (للتجربة الآن)

**الملف:** `HadCtrl-UNSIGNED-build<رقم>-<commit>.ipa` من GitHub Actions ← workflow «HadCtrl unsigned device build» ← Artifacts.
هذا الملف **غير موقّع ولا يعمل كما هو**. يعمل بعد أن توقّعه أنت بحساب Apple ID الخاص بك.

**المتطلبات:** كمبيوتر Windows أو Mac، كابل للآيفون، Apple ID (مجاني يكفي)، والآيفون على iOS 17 أو أحدث.

1. تحقق من البصمة: قارن SHA-256 للملف بما في `SHA256SUMS.txt` داخل الـ artifact نفسه.
2. ثبّت أداة توقيع محلية مثل **Sideloadly** (Windows/Mac) من موقعها الرسمي.
3. صِل الآيفون، وافتح الأداة، واسحب ملف الـ IPA إليها، وأدخل Apple ID الخاص بك، ثم ابدأ التثبيت.
   - إذا رُفض معرّف الحزمة (`invalid.hadctrl.app`)، اسمح للأداة بتغييره إلى معرّف خاص بحسابك.
4. على الآيفون: **الإعدادات ← الخصوصية والأمان ← وضع المطوّر** ← تشغيل، ثم أعد التشغيل.
5. **الإعدادات ← عام ← VPN وإدارة الجهاز** ← اختر حساب Apple ID ← «ثقة».
6. افتح «قيادة» وسجّل الدخول بحساب المدير.

**حدود هذا المسار (من Apple لا من التطبيق):** التوقيع بحساب مجاني ينتهي بعد **7 أيام** ويحتاج إعادة توقيع، ويقتصر على أجهزتك. الإشعارات الفورية لا تعمل بهذا المسار. مناسب للتجربة وليس للتوزيع على الموظفين.

---

## المسار ٢ — IPA موقّع للأجهزة المسجلة (للاستخدام الفعلي)

يُنتجه workflow «HadCtrl signed IPA» تلقائيًا بعد تجهيز ما يلي **مرة واحدة**:

1. **حساب Apple Developer Program** (اشتراك سنوي) باسم الجهة أو المالك.
2. في developer.apple.com:
   - **Identifiers:** أنشئ App ID بمعرّف نهائي، مثل `sa.<الجهة>.hadctrl` (اختره أنت؛ لا يُخترع).
   - **Devices:** سجّل **UDID** كل آيفون سيستخدم التطبيق. الـ UDID ليس الرقم التسلسلي ولا IMEI؛ يظهر في Finder/Apple Devices عند توصيل الجهاز.
   - **Certificates:** أنشئ شهادة **Apple Distribution** وصدّرها من Keychain بصيغة **.p12** مع المفتاح الخاص وكلمة مرور.
   - **Profiles:** أنشئ ملف **Ad Hoc** (Release Testing) لذلك الـ App ID يتضمن الأجهزة المسجلة، ونزّله (.mobileprovision).
3. في GitHub ← Settings ← **Environments** ← أنشئ بيئة **`ios-signing`** (يفضّل أن تشترط موافقتك):
   - **Variables:** `HC_APP_BUNDLE_ID` (المعرّف من الخطوة 2) و `HC_APPLE_TEAM_ID` (Team ID من حسابك).
   - **Secrets:** `HC_CERTIFICATE_BASE64` (ملف .p12 بصيغة Base64)، `HC_P12_PASSWORD`، `HC_PROVISION_PROFILE_BASE64` (ملف .mobileprovision بصيغة Base64)، `HC_KEYCHAIN_PASSWORD` (أي كلمة عشوائية طويلة).
   - لتحويل ملف إلى Base64: على Mac `base64 -i certificate.p12 | pbcopy`، وعلى Windows أمر PowerShell في `docs/SETUP_INPUTS_AR.md`. **لا تلصق هذه القيم في المحادثة.**
4. ادمج الفرع في `main` (طلب سحب مراجَع)، ثم GitHub ← Actions ← «HadCtrl signed IPA» ← **Run workflow** على `main`.
5. يشغّل الـ workflow كل الاختبارات أولًا، ثم يؤرشف للجهاز، ويوقّع، ويصدّر، ويتحقق من:
   - وجود `Payload/HadCtrl.app` ومطابقة معرّف الحزمة ورقم البناء؛
   - صحة التوقيع والـ entitlements و Team ID، وأن الملف غير قابل للتصحيح (non-debuggable)؛
   - أن ملف التزويد غير منتهٍ وأنه Ad Hoc بأجهزة مسجلة؛
   - أن إعداد الخادم داخل التطبيق هو مشروع Supabase الفعلي بمفتاح publishable فقط.

   ثم يرفع `HadCtrl.ipa` و `SHA256SUMS.txt` و `BUILD_REPORT.txt` و `dSYMs.zip`.
6. **التثبيت:** على Mac اسحب `HadCtrl.ipa` إلى الآيفون في نافذة Finder (أو Apple Configurator). يعمل فقط على الأجهزة المسجلة في الملف. على Windows استخدم أداة توقيع/تثبيت مع حساب المطور نفسه.

ينتهي ملف التزويد وفق مدته في حساب Apple؛ عند إضافة جهاز أو تجديد الملف، حدّث السر وأعد تشغيل الـ workflow لإنتاج بناء جديد موثّق.
