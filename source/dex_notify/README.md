@file:Suppress("DSL_SCOPE_VIOLATION") // TODO: Remove once KTIJ-19369 is fixed
plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.refine)
    alias(libs.plugins.jetbrainsKotlinAndroid)
}

android {
    namespace = "com.xayah.dex"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.xayah.dex"
        minSdk = 26
        targetSdk = 34
        versionCode = 2602
        versionName = "2.6.2-notify-daemon-ready-fix"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        multiDexEnabled = false
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "META-INF/DEPENDENCIES"
        }
    }
}

configurations.configureEach {
    exclude(group = "androidx.appcompat")
    exclude(group = "androidx.activity")
    exclude(group = "androidx.fragment")
    exclude(group = "androidx.lifecycle")
    exclude(group = "androidx.emoji2")
    exclude(group = "androidx.vectordrawable")
    exclude(group = "androidx.loader")
    exclude(group = "androidx.drawerlayout")
    exclude(group = "androidx.customview")
    exclude(group = "androidx.cursoradapter")
    exclude(group = "org.apache.httpcomponents.client5")
    exclude(group = "org.apache.httpcomponents.core5")
    exclude(group = "org.slf4j")
}

dependencies {
    testImplementation(libs.junit)
    implementation(libs.refine.runtime)
    implementation(libs.gson)

    compileOnly("androidx.annotation:annotation:1.9.1")
    compileOnly(project(":hiddenapi"))
}


## v1.4.76 修正

- 修正安裝腳本未將 `bin/mounttx` 設為 0755，導致 WebUI/Profile 切換報「缺少 native mounttx」。
- `service.sh` 新增開機自修：若 `bin/mounttx` 存在但不可執行，會自動 `chmod 0755`。
- Profile native transaction、`bindfs_shared` orchestration、rollback/probe 邏輯沿用 v1.4.75，不改掛載策略。
