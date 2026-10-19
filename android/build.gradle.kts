allprojects {
    repositories {
        google()
        mavenCentral()
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
// Some plugins compile against older Android APIs than their own
// dependencies now require (file_picker 8.x against 34, while
// flutter_plugin_android_lifecycle needs 36; irondash_engine_context against
// 31, while androidx.fragment needs 34). Compiling against a newer API
// changes nothing at run time. Registered before the block below, which
// evaluates :app straight away.
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.apply {
            if ((compileSdk ?: 0) < 36) compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
