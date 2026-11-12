allprojects {
    repositories {
        google()
        mavenCentral()
        maven("https://raw.githubusercontent.com/rustls/rustls-platform-verifier/1aa691352a5e0c215210dfc9a3c2f2078639dc91/android-release-support/maven/") {
            content { includeGroup("org.rustls") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ─────────────────────────────────────────────────────────────────────────
// flutter_inappwebview_android 1.1.3 的 build.gradle 硬编码了
// `getDefaultProguardFile('proguard-android.txt')`，而新版 AGP 已不再支持该文件
// （它带 `-dontoptimize`，会阻止 R8 优化），导致**项目配置阶段**就失败：
//
//   `getDefaultProguardFile('proguard-android.txt')` is no longer supported
//
// 错误在插件自己的 build.gradle 被求值时抛出，因此 afterEvaluate 来不及 ——
// 必须在该文件被解析**之前**打补丁。
//
// 方案：在 beforeEvaluate 阶段把插件的 build.gradle 内容读出来，把
// `proguard-android.txt` 换成 `proguard-android-optimize.txt` 写回。
// 这是项目侧的本地修复，不改 .pub-cache 的第三方源码语义（下次 pub get 也不会丢，
// 因为补丁在每次构建时重新应用）。插件发版修复后这段可删。
// ─────────────────────────────────────────────────────────────────────────
subprojects {
    if (name == "flutter_inappwebview_android") {
        beforeEvaluate {
            val gradleFile = file("build.gradle")
            if (gradleFile.exists()) {
                val original = gradleFile.readText()
                val patched = original.replace(
                    "getDefaultProguardFile('proguard-android.txt')",
                    "getDefaultProguardFile('proguard-android-optimize.txt')",
                )
                if (patched != original) {
                    gradleFile.writeText(patched)
                    logger.lifecycle(
                        "[dsh-mobile] patched flutter_inappwebview_android proguard config",
                    )
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
