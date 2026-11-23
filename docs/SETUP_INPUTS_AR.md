# قائمة إعداد HadCtrl

## يلزم لبدء الربط

| المدخل | ما الذي يُقدّم؟ |
|---|---|
| GitHub repository | رابط المستودع الذي سيُنشأ باسم HadCtrl، مع وصول Claude المناسب |
| Supabase project | المشروع المقصود، ومنطقة الاستضافة المعتمدة مؤسسيًا، دون افتراض ملكية مشروع من اسمه |
| HC_SUPABASE_URL | Project URL من إعدادات المشروع |
| HC_SUPABASE_PUBLISHABLE_KEY | مفتاح العميل القابل للنشر. لا تستخدم secret أو service_role |
| أول مدير | دعوة حساب حقيقي وتعيين عضويته من مسار إداري موثوق |
| الأقسام | الأسماء والرموز ورؤساء الأقسام. يمكن البدء ببيانات اصطناعية منفصلة |
| الهوية الرسمية | الشعار المرخّص إن وجد، والاسم المعتمد والألوان إن كانت هناك هوية ملزمة |

## يلزم لإخراج IPA قابل للتوزيع على أجهزة مسجلة

تتطلب المهمة macOS وXcode، ويمكن توفيرهما من GitHub-hosted macOS runner دون Mac شخصي. تبقى متطلبات Apple والتوقيع والتوزيع سارية.

| الاسم | نوعه في GitHub Environment: ios-signing |
|---|---|
| HC_APP_BUNDLE_ID | Variable، مطابق للهوية وملف التزويد، وليس com.example |
| HC_APPLE_TEAM_ID | Variable، معرف الفريق الصحيح |
| HC_XCODE_VERSION | Variable، إصدار مستقر موجود في صورة runner ومختبر مع المشروع |
| HC_SUPABASE_URL | Variable، إعداد عام لبيئة الإصدار الصحيحة |
| HC_SUPABASE_PUBLISHABLE_KEY | Variable، مفتاح عميل قابل للنشر فقط؛ إذا فرضت الجهة تخزينه كـ Secret تُعدّل إحالة workflow إلى secrets بدل vars |
| HC_CERTIFICATE_BASE64 | Secret، P12 يحوي شهادة التوزيع ومفتاحها الخاص |
| HC_P12_PASSWORD | Secret |
| HC_PROVISION_PROFILE_BASE64 | Secret، ملف mobileprovision المناسب للأجهزة وطريقة التصدير |
| HC_KEYCHAIN_PASSWORD | Secret، كلمة مرور عشوائية للـ Keychain المؤقت |

جهّز الشهادة والملف عبر حساب Apple Developer وإجراءاته الرسمية. شهادة عامة بلا مفتاح خاص لا تكفي. لا يضمن الاشتراك في GitHub وجود حساب Apple أو شهادة. لا تُنشأ أو تُرسل مفاتيح خاصة في المحادثة.

لتحويل ملف تملكه إلى Base64 على Windows، يمكن تشغيل الأمر محليًا ووضع الناتج في Secret المناسب:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\certificate.p12')) | Set-Clipboard
```

للملف mobileprovision يُستخدم مساره بدل مسار الشهادة. على Mac تدعم أداة base64 الخيار -i، ويمكن نسخ الناتج إلى الحافظة باستخدام pbcopy. لا تلصق القيم هنا أو في README.

## APNs

تُضاف إعدادات APNs إلى أسرار الخادم فقط عند تفعيل Push. يتحقق المطور من قدرة مزود الإرسال على HTTP/2، والتمييز بين Sandbox وProduction، وصلاحية entitlements. تستمر الإشعارات داخل التطبيق قبل اكتمال ذلك.

## ما لا يلزم الآن

لا يلزم مفتاح AI لوظائف التطبيق الأساسية، ولا يلزم نشر App Store للحصول على مسار اختبار أجهزة مسجلة. TestFlight خيار توزيع منفصل يحتاج إعداداته ويُفعّل بطلب مقصود.
