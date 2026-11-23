# مهارات HadCtrl وأدواته

حزمة المهارات المقترحة لـ Claude Code وكيف تُستخدم

اختيرت الحزمة التالية لأنها تغطي احتياج HadCtrl مباشرة: واجهات SwiftUI الأصلية، والتزامن، والاختبارات، ومراجعة أداء الواجهة، وصحة قاعدة البيانات. لا يعني وصفها بأنها موصى بها أن التطبيق يُصبح صحيحًا بمجرد تثبيتها، ولا أنها تصنيف مطلق لكل المهارات المتاحة. جرت مراجعة مستودعاتها وتعليمات التثبيت عند إعداد هذه الوثيقة. يثبت Claude النسخ المستخدمة أو يسجل commit لكل مصدر في SKILLS_LOCK.md، ويحتفظ بتراخيص المصادر إذا نُسخت ملفاتها إلى المستودع.

المهارة الأساسية للواجهة هي SwiftUI Expert من AvdLee. تُستخدم عند تقسيم الشاشات وإدارة الحالة والتنقّل والرسوم والمواد، مع الالتزام بنطاق iOS ونسخة Xcode في هذا المشروع. لا تُضاف API جديدة يذكرها المرجع إذا لم تكن متاحة للأداة المثبتة أو للنظام المستهدف [S17]. تتولى Swift Concurrency من المصدر نفسه مراجعة عزل MainActor والمهام وSendable والطلب المتأخر، وتمنع علاج التحذيرات بإضافة unchecked Sendable دون مبرر [S18].

تُستخدم Swift Testing Expert لمراجعة اختبارات المجال والتكامل والعزل والتوازي، مع إبقاء اختبارات UI في XCTest عندما تحتاجه [S19]. ويستدعى SwiftUI Performance Audit من Dimillian عند وجود بطء أو قبل بوابة الأداء، مع طلب قياس فعلي بالأدوات بدل الاكتفاء باستنتاج من الكود [S20]. لا تُثبّت عدة مهارات معمارية متعارضة ثم يطلب منها إعادة كتابة المشروع كله؛ يبقى عقد هذا المشروع هو المرجع ويقتصر كل مرجع على مجاله.

تُستخدم supabase-postgres-best-practices من مستودع Supabase الرسمي لمراجعة الفهارس وRLS وتصميم المخطط، ويمكن إضافة المهارة العامة supabase عند العمل على Auth أو Storage أو Edge Functions [S22]. هذه مراجع للمنتج الخادمي وليست ذريعة لاستخدام أمثلة JavaScript بدل عميل Swift في الآيفون. تُراجع الأمثلة حسب لغة التطبيق وعقد الخادم، ولا تستبدل سياسات HadCtrl بأمثلة تعليمية تقرأ صف المستخدم وحده إذا كان السجل مؤسسيًا يحتاج نطاق قسم ومدير.

| المهمة | المصدر الموصى به | وقت استخدامه |
|---|---|---|
| واجهات وتنقّل وحالة SwiftUI | AvdLee/SwiftUI-Agent-Skill | بناء الشاشة ومراجعة سلوكها وإتاحتها |
| تزامن Swift | AvdLee/Swift-Concurrency-Agent-Skill | الشبكات وتبديل الفترة والمهام والعزل |
| اختبارات Swift | AvdLee/Swift-Testing-Agent-Skill | الحسابات والحالة والمستودعات والتكامل |
| قياس أداء SwiftUI | Dimillian/Skills: swiftui-performance-audit | عند البطء وقبل التسليم |
| مواد Liquid Glass الاختيارية | Dimillian/Skills: swiftui-liquid-glass | عند إضافة تحكم مخصص يحتاج المرجع، دون تكرار غير لازم |
| Postgres وRLS والفهارس | supabase/agent-skills: supabase-postgres-best-practices | الترحيلات والصلاحيات والاستعلامات |
| أدوات Mac الفعلية | getsentry/MobileBuildMCP | البناء والمحاكي والتشخيص على بيئة Mac متاحة |

لـ Claude Code المحلي، تُدخل الأوامر التالية في واجهة Claude Code بوصفها أوامر plugin، لا داخل bash. أسماء الإضافات أدناه مأخوذة من تعليمات أصحابها. إذا تغير مستودع أو اسم إضافة، يراجع Claude المصدر ويحدث سجل القفل بدل الإصرار على أمر قديم. تُراجع الإضافة وتفويضاتها قبل تحميلها، ولا تمنحها صلاحيات نشر أو حذف أو أسرار لا تحتاجها مهمة التصميم.

```text
/plugin marketplace add AvdLee/SwiftUI-Agent-Skill
/plugin install swiftui-expert@swiftui-expert-skill
/plugin marketplace add AvdLee/Swift-Concurrency-Agent-Skill
/plugin install swift-concurrency@swift-concurrency-agent-skill
/plugin marketplace add AvdLee/Swift-Testing-Agent-Skill
/plugin install swift-testing-expert@swift-testing-agent-skill
```

يمكن تثبيت مرجع قاعدة البيانات بالطريقة التي توثقها Supabase، أو حفظ مجلد المهارة المحدد ضمن نطاق المشروع بعد تثبيت نسخه وتراخيصه. أما مهارة الأداء الاختيارية فيمكن إضافتها عبر أداة skills إذا كانت هذه الأداة متاحة ومراجعة لدى المستخدم. لا يلزم Node لبناء التطبيق الأصلي نفسه؛ قد تحتاجه فقط أداة تثبيت المهارات أو أداة MCP بحسب طريقة تثبيتها.

```text
claude plugin marketplace add supabase/agent-skills
claude plugin install postgres-best-practices@supabase-agent-skills
npx skills add https://github.com/Dimillian/Skills --skill swiftui-performance-audit
```

في Claude Code السحابي لا يكفي افتراض أن إضافات جهاز Mac الشخصي انتقلت إلى جلسة المستودع. يوضح دليل Claude الفرق بين نطاقات المهارات المحلية والمشروعية والسحابية؛ يمكن حفظ المهارات المطلوبة في `.claude/skills/<name>/SKILL.md` داخل المستودع وفق آلية التحميل المعتمدة، مع مراجعها الكاملة وترخيصها وقفل مصدرها [S16]. لا يكفي لصق اسم مهارة في CLAUDE.md والقول إنها مثبتة. يتحقق Claude من ظهورها أو من قراءته لملفها الفعلي، ثم يذكر ما استخدمه في تقرير التنفيذ.

أداة MobileBuildMCP هي أداة تنفيذ وليست مجرد ملف تعليمات، وكان اسمها السابق XcodeBuildMCP. توثق الجهة الحالية اسم الحزمة الجديد وأوامرها واشتراط بيئة Mac وXcode للأعمال الخاصة بمنصات Apple [S21]. على جهاز Mac يمكن تثبيتها بالطريقة الرسمية المتاحة ثم ربطها بالعميل وفق وثائقه. في بيئة Linux لا يُدّعى أن تثبيت MCP وحده وفّر Xcode أو جهاز محاكاة؛ يُستخدم GitHub macOS runner للبناء، وتوثق حدود التصحيح التفاعلي.

```text
brew tap getsentry/xcodebuildmcp
brew install mobilebuildmcp
mobilebuildmcp --help
mobilebuildmcp init
claude mcp add MobileBuildMCP -- mobilebuildmcp mcp
```

لا تُشغّل هذه الأوامر نيابة عن المستخدم من هذه الوثيقة الآن؛ إنها جزء من خطوات إعداد بيئة تنفيذ HadCtrl. لا يتطلب نجاح الإصدار الأول استخدام كل الأدوات الاختيارية. المطلوب الفعلي هو تصميم أصلي متسق وبناء واختبارات قابلة للإثبات، سواء نفذت أدوات Xcode مباشرة أو عبر تكامل موثق.

