package com.xayah.dex;

import android.annotation.SuppressLint;
import android.app.AppOpsManagerHidden;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.content.pm.ActivityInfoHidden;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.PackageManagerHidden;
import android.content.pm.PermissionInfo;
import android.os.Build;
import android.os.UserHandle;
import android.os.UserHandleHidden;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonNull;
import com.google.gson.JsonParser;
import com.xayah.dex.compat.AppOpsCompat;
import com.xayah.dex.compat.HiddenApiReflection;
import com.xayah.dex.compat.HiddenApiServices;
import com.xayah.dex.compat.PermissionCompat;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import dev.rikka.tools.refine.Refine;

/**
 * Structured App state engine shared by the one-shot CLI and the persistent AF_UNIX daemon.
 *
 * Output is UTF-8 NDJSON. Every package record carries an explicit result object, so callers
 * never need to infer success/failure from translated text. The final record is always a
 * summary record. Snapshot, restore and verify share this single canonical schema; the former
 * HiddenApiUtil token-section AppState protocol has been removed.
 */
public final class AppStateEngine {
    public static final int SCHEMA_VERSION = 2;
    public static final int DAEMON_PROTOCOL_VERSION = 1;
    public static final String ENGINE_VERSION = "v1.3.1-notify-daemon-ready-fix";

    static final Gson GSON = new GsonBuilder().serializeNulls().disableHtmlEscaping().create();
    static final Gson PRETTY_GSON = new GsonBuilder().serializeNulls().disableHtmlEscaping().setPrettyPrinting().create();

    public enum ResultCode {
        OK(0, false),
        PARTIAL(10, true),
        BAD_REQUEST(20, false),
        PACKAGE_NOT_FOUND(30, false),
        UNSUPPORTED(40, false),
        PERMISSION_DENIED(50, false),
        VERIFY_MISMATCH(60, false),
        INTERNAL_ERROR(70, true);

        public final int code;
        public final boolean retryable;

        ResultCode(int code, boolean retryable) {
            this.code = code;
            this.retryable = retryable;
        }
    }

    public static final class EngineResponse {
        public final ResultCode resultCode;
        public final String body;

        public EngineResponse(ResultCode resultCode, String body) {
            this.resultCode = resultCode;
            this.body = body == null ? "" : body;
        }

        public int processExitCode() {
            if (resultCode == ResultCode.OK || resultCode == ResultCode.PARTIAL || resultCode == ResultCode.VERIFY_MISMATCH) {
                return 0;
            }
            return resultCode == ResultCode.BAD_REQUEST ? 2 : 1;
        }
    }

    private static final class SpecialAccessDescriptor {
        final String key;
        final String publicName;
        final String manifestPermission;
        final boolean requirePictureInPictureActivity;

        SpecialAccessDescriptor(String key, String publicName, String manifestPermission,
                                boolean requirePictureInPictureActivity) {
            this.key = key;
            this.publicName = publicName;
            this.manifestPermission = manifestPermission;
            this.requirePictureInPictureActivity = requirePictureInPictureActivity;
        }
    }

    private static final class GooglePackageSnapshot {
        String state = "missing";
        String enabledState = "missing";
        String uid = "null";
        String versionCode = "null";
        String runInBackgroundMode = "null";
        String runAnyInBackgroundMode = "null";
        String deviceIdleWhitelist = "false";
    }

    private static final List<SpecialAccessDescriptor> SPECIAL_ACCESS = Collections.unmodifiableList(Arrays.asList(
            new SpecialAccessDescriptor("SYSTEM_ALERT_WINDOW", "android:system_alert_window", "android.permission.SYSTEM_ALERT_WINDOW", false),
            new SpecialAccessDescriptor("PICTURE_IN_PICTURE", "android:picture_in_picture", null, true),
            new SpecialAccessDescriptor("MANAGE_EXTERNAL_STORAGE", "android:manage_external_storage", "android.permission.MANAGE_EXTERNAL_STORAGE", false),
            new SpecialAccessDescriptor("WRITE_SETTINGS", "android:write_settings", "android.permission.WRITE_SETTINGS", false),
            new SpecialAccessDescriptor("REQUEST_INSTALL_PACKAGES", "android:request_install_packages", "android.permission.REQUEST_INSTALL_PACKAGES", false),
            new SpecialAccessDescriptor("GET_USAGE_STATS", "android:get_usage_stats", "android.permission.PACKAGE_USAGE_STATS", false),
            new SpecialAccessDescriptor("USE_FULL_SCREEN_INTENT", "android:use_full_screen_intent", "android.permission.USE_FULL_SCREEN_INTENT", false),
            new SpecialAccessDescriptor("SCHEDULE_EXACT_ALARM", "android:schedule_exact_alarm", "android.permission.SCHEDULE_EXACT_ALARM", false),
            new SpecialAccessDescriptor("ACCESS_NOTIFICATION_POLICY", "android:access_notification_policy", "android.permission.ACCESS_NOTIFICATION_POLICY", false)
    ));

    private static final Map<String, SpecialAccessDescriptor> SPECIAL_ACCESS_BY_KEY = buildSpecialAccessMap();
    private static final Map<String, Integer> OP_CACHE = new HashMap<>();
    private static final Map<String, int[]> PERMISSION_PROTECTION_CACHE = new HashMap<>();
    private static final Object RUNTIME_LOCK = new Object();
    private static volatile RuntimeServices RUNTIME_SERVICES;

    private static final class RuntimeServices {
        final Context context;
        final PackageManager packageManager;
        final PackageManagerHidden packageManagerHidden;
        final AppOpsManagerHidden appOpsManager;

        RuntimeServices(Context context, PackageManager packageManager,
                        PackageManagerHidden packageManagerHidden,
                        AppOpsManagerHidden appOpsManager) {
            this.context = context;
            this.packageManager = packageManager;
            this.packageManagerHidden = packageManagerHidden;
            this.appOpsManager = appOpsManager;
        }
    }

    private AppStateEngine() {
    }

    /** Initializes Context and Binder-backed services once before daemon READY. */
    @SuppressLint("ServiceCast")
    public static void initializeRuntime() throws Exception {
        runtimeServices();
    }

    @SuppressLint("ServiceCast")
    private static RuntimeServices runtimeServices() throws Exception {
        RuntimeServices cached = RUNTIME_SERVICES;
        if (cached != null) return cached;
        synchronized (RUNTIME_LOCK) {
            cached = RUNTIME_SERVICES;
            if (cached != null) return cached;
            Context context = HiddenApiHelper.initializeContext();
            PackageManager packageManager = PackageManagerUtil.getPackageManager(context).packageManager();
            PackageManagerHidden packageManagerHidden = Refine.unsafeCast(packageManager);
            AppOpsManagerHidden appOpsManager =
                    (AppOpsManagerHidden) context.getSystemService(Context.APP_OPS_SERVICE);
            if (appOpsManager == null) {
                throw new IllegalStateException("APP_OPS_SERVICE unavailable");
            }
            cached = new RuntimeServices(context, packageManager, packageManagerHidden, appOpsManager);
            RUNTIME_SERVICES = cached;
            return cached;
        }
    }

    public static synchronized EngineResponse dispatch(String command, int userId, String extra, String body) {
        try {
            switch (normalizeCommand(command)) {
                case "ping":
                    return new EngineResponse(ResultCode.OK, "PONG\n");
                case "capabilities":
                    return capabilities("pretty".equalsIgnoreCase(extra));
                case "snapshot":
                    return snapshot(userId, parsePackageLines(body));
                case "restore":
                    return restoreAppState(userId, body);
                case "verify":
                    return verifyAppState(userId, body);
                default:
                    return errorResponse(ResultCode.BAD_REQUEST, "dispatch", null,
                            "unknown command: " + safe(command));
            }
        } catch (IllegalArgumentException e) {
            return errorResponse(ResultCode.BAD_REQUEST, normalizeCommand(command), null, failureMessage(e));
        } catch (SecurityException e) {
            return errorResponse(ResultCode.PERMISSION_DENIED, normalizeCommand(command), null, failureMessage(e));
        } catch (Throwable e) {
            return errorResponse(ResultCode.INTERNAL_ERROR, normalizeCommand(command), null, failureMessage(e));
        }
    }

    public static EngineResponse capabilities(boolean pretty) {
        JsonObject root = new JsonObject();
        root.addProperty("schemaVersion", SCHEMA_VERSION);
        root.addProperty("daemonProtocolVersion", DAEMON_PROTOCOL_VERSION);
        root.addProperty("engineVersion", ENGINE_VERSION);
        root.addProperty("dexVersion", HiddenApiUtil.VERSION);
        root.addProperty("mainClass", "com.xayah.dex.AppStateUtil");

        JsonArray resultCodes = new JsonArray();
        for (ResultCode code : ResultCode.values()) {
            JsonObject item = new JsonObject();
            item.addProperty("name", code.name());
            item.addProperty("code", code.code);
            item.addProperty("retryable", code.retryable);
            resultCodes.add(item);
        }
        root.add("resultCodes", resultCodes);

        JsonArray capabilities = new JsonArray();
        addCapability(capabilities, "dex.capabilities.v1", true, true, "json");
        addCapability(capabilities, "dex.machine_stdout.v1", true, true, "stdout=data-only;stderr=diagnostic");
        addCapability(capabilities, "appstate.snapshot.batch.v2", true, true, "canonical-ndjson");
        addCapability(capabilities, "appstate.shared_payload.v1", true, true, "snapshot=restore=verify");
        addCapability(capabilities, "appstate.special_access.integrated.v1", true, true, "snapshot+restore+verify");
        addCapability(capabilities, "appstate.restore.batch.v3", true, true, "canonical-ndjson+structured-items");
        addCapability(capabilities, "appstate.verify.batch.v3", true, true, "canonical-ndjson+structured-mismatch");
        addCapability(capabilities, "appstate.restore.batch.v4", true, true, "runtime-permission-uid-op+explicit-package-op");
        addCapability(capabilities, "appstate.verify.batch.v4", true, true, "effective-runtime-op+stable-flags");
        addCapability(capabilities, "appstate.appops_reset.integrated.v1", true, true, "package-scoped");
        addCapability(capabilities, "appstate.ssaid.integrated.v1", true, true, "snapshot+restore+verify");
        addCapability(capabilities, "appstate.daemon.af_unix.v1", true, true, "stream-framed");
        addCapability(capabilities, "appstate.daemon.runtime_preinit.v1", true, true, "context+pm+appops-before-ready");
        addCapability(capabilities, "appstate.structured_result_codes.v2", true, true, "result-header+package+item-ndjson");
        addCapability(capabilities, "appstate.scoped_appops_fields.v1", true, true, "packageMode+uidMode+effectiveMode");
        addCapability(capabilities, "appstate.explicit_package_mode_snapshot.v1", true, true, "getOpsForPackage-not-effective-check");
        addCapability(capabilities, "appstate.default_appop_missing_equivalent.v1", true, true, "missing-row-equals-mode-default");
        addCapability(capabilities, "appstate.permission_denied_item_partial.v1", true, true, "item-level-securityexception-does-not-poison-batch");
        addCapability(capabilities, "appstate.legacy_permission_normalize.v1", true, true, "skip-nonchangeable-grants+special-appop-permission-bridge");
        addCapability(capabilities, "appstate.non_ok_structured_body.v1", true, true, "daemon-body-kept-for-non-ok-package-results");
        addCapability(capabilities, "appstate.runtime_permission_uid_restore.v1", true, true, "clear-package+set-uid-effective-mode");
        addCapability(capabilities, "appstate.permission_flags.stable_mask.v1", true, true, "exclude-os-managed-revoked-compat");
        addCapability(capabilities, "appstate.special_access.deduplicated.v1", true, true, "special-op-owned-by-specialAccess");
        addCapability(capabilities, "appstate.batch_preflight_validation.v1", true, true, "reject-before-mutation");
        addCapability(capabilities, "appstate.token_sections", false, false, "removed");
        addCapability(capabilities, "appops.reset.package_batch", false, false, "removed-from-public-surface");
        addCapability(capabilities, "webdav.daemon.af_unix", true, true, "stream-framed");
        addCapability(capabilities, "webdav.empty_body_retry_before_payload", true, true, "internal");
        addCapability(capabilities, "notification.speedbackup_status", true, false, "notifyBatch");
        addCapability(capabilities, "hiddenapi.daemon.af_unix.v1", true, true, "getPackageUid+precheckInstallApks+getInstallSourceInfo+installSessionBatch");
        addCapability(capabilities, "hiddenapi.hot_cli_removed.v1", true, true, "hot commands are daemon-only");
        addCapability(capabilities, "notification.daemon.af_unix.v1", true, true, "notifyBatch");
        addCapability(capabilities, "notification.hot_cli_removed.v1", true, true, "notifyBatch is daemon-only");
        addCapability(capabilities, "notification.app_settings_backup_restore", false, false, "removed");
        root.add("capabilities", capabilities);

        JsonArray specialKeys = new JsonArray();
        for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) {
            specialKeys.add(descriptor.key);
        }
        root.add("specialAccessKeys", specialKeys);

        return new EngineResponse(ResultCode.OK, (pretty ? PRETTY_GSON : GSON).toJson(root) + "\n");
    }

    @SuppressLint("ServiceCast")
    static EngineResponse snapshot(int userId, List<String> packageNames) {
        List<String> packages = dedupePackages(packageNames);
        if (packages.isEmpty()) {
            return batchSummaryOnly("snapshotAppStateBatch", ResultCode.BAD_REQUEST, 0, 0, 0, 0,
                    "no packages");
        }

        StringBuilder out = new StringBuilder();
        int ok = 0;
        int partial = 0;
        int failed = 0;
        try {
            RuntimeServices runtime = runtimeServices();
            PackageManager realPm = runtime.packageManager;
            PackageManagerHidden pmHidden = runtime.packageManagerHidden;
            AppOpsManagerHidden appOps = runtime.appOpsManager;
            Set<String> idleWhitelist = getDeviceIdleWhitelist();
            UserHandle user = UserHandleHidden.of(userId);
            GooglePackageSnapshot playStore = googlePackageSnapshot(
                    realPm, pmHidden, appOps, idleWhitelist, userId, "com.android.vending");
            GooglePackageSnapshot playServices = googlePackageSnapshot(
                    realPm, pmHidden, appOps, idleWhitelist, userId, "com.google.android.gms");

            for (String packageName : packages) {
                JsonObject record;
                try {
                    record = snapshotPackage(realPm, pmHidden, appOps, idleWhitelist, user, userId, packageName,
                            playStore, playServices);
                } catch (PackageManager.NameNotFoundException e) {
                    record = packageErrorRecord("snapshot", userId, packageName, ResultCode.PACKAGE_NOT_FOUND, failureMessage(e));
                } catch (SecurityException e) {
                    record = packageErrorRecord("snapshot", userId, packageName, ResultCode.PERMISSION_DENIED, failureMessage(e));
                } catch (Throwable e) {
                    record = packageErrorRecord("snapshot", userId, packageName, ResultCode.INTERNAL_ERROR, failureMessage(e));
                }
                ResultCode code = resultCodeFromRecord(record);
                if (code == ResultCode.OK) ok++;
                else if (code == ResultCode.PARTIAL) partial++;
                else failed++;
                out.append(GSON.toJson(record)).append('\n');
            }
        } catch (SecurityException e) {
            return errorResponse(ResultCode.PERMISSION_DENIED, "snapshotAppStateBatch", null, failureMessage(e));
        } catch (Throwable e) {
            return errorResponse(ResultCode.INTERNAL_ERROR, "snapshotAppStateBatch", null, failureMessage(e));
        }

        ResultCode overall = failed > 0 || partial > 0 ? ResultCode.PARTIAL : ResultCode.OK;
        out.append(GSON.toJson(summaryRecord("snapshotAppStateBatch", overall, packages.size(), ok, partial, failed, null))).append('\n');
        return new EngineResponse(overall, out.toString());
    }

    static EngineResponse restoreAppState(int userId, String body) {
        return processCanonicalBatch("restoreAppStateBatch", userId, body, false);
    }

    static EngineResponse verifyAppState(int userId, String body) {
        return processCanonicalBatch("verifyAppStateBatch", userId, body, true);
    }

    @SuppressLint("ServiceCast")
    private static EngineResponse processCanonicalBatch(String command, int userId, String body, boolean verifyOnly) {
        final List<JsonObject> records;
        try {
            records = parseJsonRecords(body);
        } catch (IllegalArgumentException e) {
            return errorResponse(ResultCode.BAD_REQUEST, command, null, failureMessage(e));
        }
        if (records.isEmpty()) {
            return batchSummaryOnly(command, ResultCode.BAD_REQUEST, 0, 0, 0, 0,
                    "no canonical AppState records");
        }

        // Validate the complete batch before obtaining mutable services or touching any package.
        // A malformed/schema-incompatible record rejects the whole request with BAD_REQUEST.
        for (int i = 0; i < records.size(); i++) {
            JsonObject desired = records.get(i);
            String packageName = stringMember(desired, "packageName");
            try {
                validateCanonicalRecord(desired, packageName);
            } catch (IllegalArgumentException e) {
                return batchSummaryOnly(command, ResultCode.BAD_REQUEST, records.size(), 0, 0,
                        records.size(), "record=" + (i + 1) + " " + failureMessage(e));
            }
        }

        StringBuilder out = new StringBuilder();
        int ok = 0;
        int partial = 0;
        int failed = 0;
        ResultCode uniformFailure = null;
        boolean mixedFailures = false;
        try {
            RuntimeServices runtime = runtimeServices();
            PackageManager realPm = runtime.packageManager;
            PackageManagerHidden pmHidden = runtime.packageManagerHidden;
            AppOpsManagerHidden appOps = runtime.appOpsManager;
            UserHandle user = UserHandleHidden.of(userId);
            Set<String> idleWhitelist = getDeviceIdleWhitelist();
            GooglePackageSnapshot playStore = verifyOnly
                    ? googlePackageSnapshot(realPm, pmHidden, appOps, idleWhitelist, userId, "com.android.vending")
                    : null;
            GooglePackageSnapshot playServices = verifyOnly
                    ? googlePackageSnapshot(realPm, pmHidden, appOps, idleWhitelist, userId, "com.google.android.gms")
                    : null;

            for (JsonObject desired : records) {
                String packageName = stringMember(desired, "packageName");
                JsonObject result;
                try {
                    result = verifyOnly
                            ? verifyPackageState(realPm, pmHidden, appOps, user, userId, packageName,
                            desired, playStore, playServices)
                            : restorePackageState(realPm, pmHidden, appOps, user, userId, packageName, desired);
                } catch (PackageManager.NameNotFoundException e) {
                    result = packageErrorRecord(verifyOnly ? "verify" : "restore", userId, packageName,
                            ResultCode.PACKAGE_NOT_FOUND, failureMessage(e));
                } catch (IllegalArgumentException e) {
                    result = packageErrorRecord(verifyOnly ? "verify" : "restore", userId, packageName,
                            ResultCode.BAD_REQUEST, failureMessage(e));
                } catch (SecurityException e) {
                    result = packageErrorRecord(verifyOnly ? "verify" : "restore", userId, packageName,
                            ResultCode.PERMISSION_DENIED, failureMessage(e));
                } catch (Throwable e) {
                    result = packageErrorRecord(verifyOnly ? "verify" : "restore", userId, packageName,
                            ResultCode.INTERNAL_ERROR, failureMessage(e));
                }
                ResultCode code = resultCodeFromRecord(result);
                if (code == ResultCode.OK) {
                    ok++;
                } else if (code == ResultCode.PARTIAL || code == ResultCode.VERIFY_MISMATCH) {
                    partial++;
                } else {
                    failed++;
                    if (uniformFailure == null) uniformFailure = code;
                    else if (uniformFailure != code) mixedFailures = true;
                }
                out.append(GSON.toJson(result)).append('\n');
            }
        } catch (SecurityException e) {
            return errorResponse(ResultCode.PERMISSION_DENIED, command, null, failureMessage(e));
        } catch (Throwable e) {
            return errorResponse(ResultCode.INTERNAL_ERROR, command, null, failureMessage(e));
        }

        ResultCode overall;
        if (failed == records.size() && partial == 0 && ok == 0
                && uniformFailure != null && !mixedFailures) {
            // Preserve a homogeneous terminal error in the daemon RESULT header and one-shot exit code.
            overall = uniformFailure;
        } else if (failed > 0) {
            overall = ResultCode.PARTIAL;
        } else if (partial > 0) {
            overall = verifyOnly ? ResultCode.VERIFY_MISMATCH : ResultCode.PARTIAL;
        } else {
            overall = ResultCode.OK;
        }
        out.append(GSON.toJson(summaryRecord(command, overall, records.size(), ok, partial, failed, null))).append('\n');
        return new EngineResponse(overall, out.toString());
    }

    private static void validateCanonicalRecord(JsonObject record, String packageName) {
        if (record == null) throw new IllegalArgumentException("record is null");
        if (packageName == null || packageName.trim().isEmpty()) {
            throw new IllegalArgumentException("packageName is empty");
        }
        int schema = intMember(record, "schemaVersion", -1);
        if (schema != SCHEMA_VERSION) {
            throw new IllegalArgumentException("unsupported schemaVersion=" + schema);
        }
        if (!"snapshot".equals(stringMember(record, "recordType"))) {
            throw new IllegalArgumentException("recordType must be snapshot");
        }
        if (!record.has("permissions") || !record.get("permissions").isJsonArray()) {
            throw new IllegalArgumentException("permissions must be an array");
        }
        if (!record.has("specialAccess") || !record.get("specialAccess").isJsonObject()) {
            throw new IllegalArgumentException("specialAccess must be an object");
        }
        if (!record.has("otherAppOps") || !record.get("otherAppOps").isJsonArray()) {
            throw new IllegalArgumentException("otherAppOps must be an array");
        }
        if (!record.has("batterySettings") || !record.get("batterySettings").isJsonObject()) {
            throw new IllegalArgumentException("batterySettings must be an object");
        }
        validateScopedOpContract(record);
    }

    private static final class OperationReport {
        final JsonArray items = new JsonArray();
        final JsonArray errors = new JsonArray();
        ResultCode result = ResultCode.OK;

        void success(String category, String key, String message) {
            JsonObject item = operationItem(category, key, ResultCode.OK, message);
            items.add(item);
        }

        void note(String category, String key, ResultCode code, String message) {
            JsonObject item = operationItem(category, key, code, message);
            items.add(item);
            if (code != ResultCode.OK) result = mergeResult(result, code);
        }

        void failure(String category, String key, Throwable throwable) {
            ResultCode code = classifyThrowable(throwable);
            JsonObject item = operationItem(category, key, code, failureMessage(throwable));
            items.add(item);
            errors.add(errorObject(category + (key == null || key.isEmpty() ? "" : "." + key),
                    code, failureMessage(throwable)));
            // Item-level SecurityException is expected on some Android 16 / vendor AppOps
            // and settings rows. Keep the per-item PERMISSION_DENIED detail, but do not
            // let a single denied item turn the whole package/daemon header into a
            // transport-like terminal failure. Callers must still receive the structured
            // body and continue to verify the rest of the restored state.
            ResultCode aggregate = (code == ResultCode.UNSUPPORTED || code == ResultCode.PERMISSION_DENIED)
                    ? ResultCode.PARTIAL : code;
            result = mergeResult(result, aggregate);
        }

        void mismatch(String category, String key, String message) {
            JsonObject item = operationItem(category, key, ResultCode.VERIFY_MISMATCH, message);
            items.add(item);
            result = mergeResult(result, ResultCode.VERIFY_MISMATCH);
        }
    }

    private static JsonObject operationItem(String category, String key, ResultCode code, String message) {
        JsonObject item = new JsonObject();
        item.addProperty("category", category == null ? "" : category);
        item.addProperty("key", key == null ? "" : key);
        setResult(item, code, message);
        return item;
    }

    private static JsonObject restorePackageState(PackageManager realPm, PackageManagerHidden pmHidden,
                                                  AppOpsManagerHidden appOps, UserHandle user, int userId,
                                                  String packageName, JsonObject desired) throws Exception {
        PackageInfo packageInfo = pmHidden.getPackageInfoAsUser(packageName, snapshotPackageFlags(), userId);
        if (packageInfo == null || packageInfo.applicationInfo == null) {
            throw new PackageManager.NameNotFoundException(packageName);
        }
        int uid = packageInfo.applicationInfo.uid;
        OperationReport report = new OperationReport();
        JsonObject root = baseRecord("restore", userId, packageName);
        Set<Integer> expectedOps = collectExpectedOps(desired);

        AppOpsCompat.ResetResult reset = AppOpsCompat.resetPackageModesSafe(appOps, userId, packageName);
        if (reset.ok) {
            report.success("appOpsReset", packageName,
                    "package-scoped resetAllModes signature=" + reset.signature + " cached=" + reset.cached);
        } else {
            int resetCount = AppOpsCompat.resetKnownOpsToDefault(appOps, uid, packageName,
                    expectedOps, AppStateEngine::publicOpName);
            if (expectedOps.isEmpty() || resetCount == expectedOps.size()) {
                report.success("appOpsReset", packageName,
                        "package-scoped reset unavailable; package-only known-op fallback="
                                + resetCount + "/" + expectedOps.size());
            } else if (resetCount > 0) {
                report.note("appOpsReset", packageName, ResultCode.PARTIAL,
                        "package-only known-op fallback incomplete=" + resetCount
                                + "/" + expectedOps.size());
            } else {
                report.failure("appOpsReset", packageName,
                        new UnsupportedOperationException("package-scoped AppOps reset unavailable"));
            }
        }

        Set<String> requestedPermissions = new HashSet<>();
        if (packageInfo.requestedPermissions != null) {
            requestedPermissions.addAll(Arrays.asList(packageInfo.requestedPermissions));
        }
        int permissionMask = permissionFlagRestoreMask();
        JsonArray permissions = desired.getAsJsonArray("permissions");
        for (JsonElement element : permissions) {
            if (!element.isJsonObject()) continue;
            JsonObject permission = element.getAsJsonObject();
            String name = stringMember(permission, "name");
            if (name.isEmpty()) continue;
            boolean runtime = booleanMember(permission, "runtime", false);
            boolean development = booleanMember(permission, "development", false);
            int op = intMember(permission, "appOp", AppOpsManagerHidden.OP_NONE);
            boolean specialAccessOp = isSpecialAccessOp(op);
            boolean changeableGrant = isChangeablePermissionGrant(realPm, name, runtime, development);
            if (!requestedPermissions.contains(name)) {
                report.note("permission", name, ResultCode.UNSUPPORTED, "permission not requested by installed package");
                continue;
            }
            // Legacy app_details sometimes marked install-time or special-access permissions
            // (FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE, SYSTEM_ALERT_WINDOW,
            // PACKAGE_USAGE_STATS, DUMP, etc.) as runtime=true. Android correctly rejects
            // grant/revoke for those with "not a changeable permission type". The AppOp and
            // flags remain restorable; the permission grant itself is not a failure.
            if ((runtime || development) && changeableGrant && !specialAccessOp) {
                try {
                    boolean granted = booleanMember(permission, "granted", false);
                    if (granted) pmHidden.grantRuntimePermission(packageName, name, user);
                    else pmHidden.revokeRuntimePermission(packageName, name, user);
                    report.success("permissionGrant", name, granted ? "granted" : "revoked");
                } catch (Throwable e) {
                    report.failure("permissionGrant", name, e);
                }
            } else if (runtime || development || specialAccessOp) {
                report.success("permissionGrant", name, "skipped non-changeable or special-access permission");
            }
            if (permission.has("flags") && !permission.get("flags").isJsonNull() && !specialAccessOp) {
                try {
                    int flags = intMember(permission, "flags", 0);
                    PermissionCompat.updatePermissionFlags(pmHidden, packageName, name,
                            permissionMask, flags & permissionMask, userId, user);
                    report.success("permissionFlags", name, "flags=" + flags + " mask=" + permissionMask);
                } catch (Throwable e) {
                    report.failure("permissionFlags", name, e);
                }
            }
            if (op != AppOpsManagerHidden.OP_NONE) {
                if (changeableGrant && runtime && !specialAccessOp) {
                    restoreRuntimePermissionAppOp(appOps, uid, packageName, permission, op,
                            "permissionAppOp", name, report);
                } else {
                    // For legacy-migrated permission rows that are not emitted by the new
                    // snapshot schema, bridge their AppOp into the scoped writer so old
                    // backups still restore the meaningful state without creating verify noise.
                    restoreScopedAppOp(appOps, uid, packageName, permission, op, "appOpMode",
                            "permissionAppOp", name, false, report);
                }
            }
        }

        JsonObject special = desired.getAsJsonObject("specialAccess");
        for (Map.Entry<String, JsonElement> entry : special.entrySet()) {
            if (!entry.getValue().isJsonObject()) continue;
            JsonObject state = entry.getValue().getAsJsonObject();
            if (!booleanMember(state, "supported", true)
                    || !booleanMember(state, "requested", false)) continue;
            int op = intMember(state, "op", AppOpsManagerHidden.OP_NONE);
            if (op == AppOpsManagerHidden.OP_NONE) {
                report.note("specialAccess", entry.getKey(), ResultCode.UNSUPPORTED, "AppOp unavailable");
                continue;
            }
            restoreScopedAppOp(appOps, uid, packageName, state, op, "mode",
                    "specialAccess", entry.getKey(), false, report);
        }

        JsonArray otherOps = desired.getAsJsonArray("otherAppOps");
        for (JsonElement element : otherOps) {
            if (!element.isJsonObject()) continue;
            JsonObject state = element.getAsJsonObject();
            int op = intMember(state, "op", AppOpsManagerHidden.OP_NONE);
            if (op == AppOpsManagerHidden.OP_NONE) continue;
            restoreScopedAppOp(appOps, uid, packageName, state, op, "mode",
                    "otherAppOp", publicOpName(op), false, report);
        }

        JsonObject battery = desired.getAsJsonObject("batterySettings");
        restoreBatteryOp(appOps, uid, packageName, battery, "RUN_IN_BACKGROUND", report);
        restoreBatteryOp(appOps, uid, packageName, battery, "RUN_ANY_IN_BACKGROUND", report);
        if (battery.has("deviceidleWhitelist") && !battery.get("deviceidleWhitelist").isJsonNull()) {
            try {
                boolean enabled = battery.get("deviceidleWhitelist").getAsBoolean();
                setDeviceIdleWhitelist(packageName, enabled);
                report.success("battery", "deviceidleWhitelist", String.valueOf(enabled));
            } catch (Throwable e) {
                report.failure("battery", "deviceidleWhitelist", e);
            }
        }

        if (desired.has("ssaid") && !desired.get("ssaid").isJsonNull()) {
            String ssaid = stringMember(desired, "ssaid");
            if (!ssaid.isEmpty()) {
                try {
                    SsaidUtil.writeSsaidValue(userId, packageName, ssaid, pmHidden);
                    String readBack = SsaidUtil.readSsaidValue(userId, packageName, pmHidden);
                    if (ssaid.equals(readBack)) report.success("ssaid", packageName, "write/readback matched");
                    else report.mismatch("ssaid", packageName, "expected=" + ssaid + " actual=" + safe(readBack));
                } catch (Throwable e) {
                    report.failure("ssaid", packageName, e);
                }
            }
        }

        root.add("items", report.items);
        if (report.errors.size() > 0) root.add("errors", report.errors);
        setResult(root, report.result, report.result == ResultCode.OK ? null : "one or more AppState items did not fully restore");
        return root;
    }

    private static void restoreBatteryOp(AppOpsManagerHidden appOps, int uid, String packageName,
                                         JsonObject battery, String key, OperationReport report) {
        JsonObject state = objectMember(battery, key);
        if (state == null || !booleanMember(state, "supported", true)) return;
        int op = intMember(state, "op", AppOpsManagerHidden.OP_NONE);
        if (op == AppOpsManagerHidden.OP_NONE) return;
        restoreScopedAppOp(appOps, uid, packageName, state, op, "mode", "battery", key, true, report);
    }

    private static void restoreRuntimePermissionAppOp(AppOpsManagerHidden appOps, int uid,
                                                      String packageName, JsonObject state, int op,
                                                      String category, String key,
                                                      OperationReport report) {
        try {
            int expectedEffective = intMember(state, "appOpMode", AppOpsManagerHidden.MODE_DEFAULT);
            AppOpsCompat.setRuntimePermissionUidMode(appOps, op, uid, expectedEffective,
                    packageName, AppStateEngine::publicOpName);
            int actualEffective = readEffectiveModeWithRetry(appOps, op, uid, packageName, expectedEffective);
            if (modeEquivalent(expectedEffective, actualEffective)) {
                report.success(category, key, "op=" + op + " uidMode=" + expectedEffective
                        + " effective=" + actualEffective);
            } else {
                report.mismatch(category, key, "op=" + op
                        + " expectedEffective=" + expectedEffective
                        + " actualEffective=" + actualEffective
                        + " strategy=runtime_permission_uid");
            }
        } catch (Throwable e) {
            report.failure(category, key, e);
        }
    }

    private static void restoreScopedAppOp(AppOpsManagerHidden appOps, int uid, String packageName,
                                           JsonObject state, int op, String effectiveField,
                                           String category, String key, boolean mirrorUidWhenUnknown,
                                           OperationReport report) {
        try {
            Integer packageMode = nullableIntMember(state, "packageMode");
            Integer uidMode = nullableIntMember(state, "uidMode");
            int expectedEffective = intMember(state, effectiveField, AppOpsManagerHidden.MODE_DEFAULT);

            // JSON null means that scope could not be observed, not MODE_DEFAULT. Do not erase an
            // unknown scope. Package mode is restored only when it carries an actual integer.
            if (packageMode != null) {
                AppOpsCompat.setPackageModeIfNeeded(appOps, op, uid, packageName, packageMode);
            }
            if (uidMode != null) {
                AppOpsCompat.setUidModeIfNeeded(appOps, op, uid, uidMode,
                        AppStateEngine::publicOpName);
            } else if (mirrorUidWhenUnknown) {
                // Android 16/vendor battery AppOps may be uid-authoritative even when getUidMode
                // is hidden. Mirror the desired effective mode, matching the proven legacy path.
                AppOpsCompat.setUidModeIfNeeded(appOps, op, uid, expectedEffective,
                        AppStateEngine::publicOpName);
            }

            Integer actualPackage = AppOpsCompat.tryGetPackageModeRaw(appOps, op, uid, packageName);
            Integer actualUid = AppOpsCompat.tryGetUidModeRaw(appOps, op, uid, AppStateEngine::publicOpName);
            int actualEffective = readEffectiveModeWithRetry(appOps, op, uid, packageName, expectedEffective);
            boolean packageOk = packageMode == null || nullableModeEquivalent(packageMode, actualPackage);
            boolean uidOk = uidMode == null || nullableModeEquivalent(uidMode, actualUid);
            boolean explicitScopeOk = (packageMode != null || uidMode != null) && packageOk && uidOk;
            boolean effectiveOk = modeEquivalent(expectedEffective, actualEffective)
                    || (explicitScopeOk && isEffectiveModeAdvisory(op));
            if (packageOk && uidOk && effectiveOk) {
                String suffix = isEffectiveModeAdvisory(op) && !modeEquivalent(expectedEffective, actualEffective)
                        ? " advisoryEffective=" + actualEffective
                        : " mode=" + actualEffective;
                report.success(category, key, "op=" + op + suffix
                        + " packageMode=" + String.valueOf(actualPackage)
                        + " uidMode=" + String.valueOf(actualUid));
            } else {
                report.mismatch(category, key, "op=" + op
                        + " expectedEffective=" + expectedEffective + " actualEffective=" + actualEffective
                        + " expectedPackage=" + String.valueOf(packageMode) + " actualPackage=" + String.valueOf(actualPackage)
                        + " expectedUid=" + String.valueOf(uidMode) + " actualUid=" + String.valueOf(actualUid));
            }
        } catch (Throwable e) {
            report.failure(category, key, e);
        }
    }

    private static boolean isEffectiveModeAdvisory(int op) {
        // OP_START_FOREGROUND / android:start_foreground. Package mode is restorable,
        // but effective mode may stay MODE_DEFAULT on Android 16 vendor builds.
        return op == 76;
    }

    private static int readEffectiveModeWithRetry(AppOpsManagerHidden appOps, int op, int uid,
                                                   String packageName, int expected) {
        int actual = getEffectiveOpMode(appOps, op, uid, packageName);
        for (int attempt = 0; attempt < 3 && !modeEquivalent(expected, actual); attempt++) {
            try {
                Thread.sleep(20L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
            actual = getEffectiveOpMode(appOps, op, uid, packageName);
        }
        return actual;
    }

    private static JsonObject verifyPackageState(PackageManager realPm, PackageManagerHidden pmHidden,
                                                 AppOpsManagerHidden appOps, UserHandle user, int userId,
                                                 String packageName, JsonObject desired,
                                                 GooglePackageSnapshot playStore,
                                                 GooglePackageSnapshot playServices) throws Exception {
        Set<String> idleWhitelist = getDeviceIdleWhitelist();
        PackageInfo packageInfo = pmHidden.getPackageInfoAsUser(packageName, snapshotPackageFlags(), userId);
        JsonObject current = snapshotPackage(realPm, pmHidden, appOps, idleWhitelist, user, userId,
                packageName, playStore, playServices);
        JsonObject root = baseRecord("verify", userId, packageName);
        JsonArray mismatches = new JsonArray();

        compareInstallState(desired, current, mismatches);
        comparePermissionState(desired, current, mismatches);
        compareSpecialAccessState(desired, current, mismatches);
        compareOtherAppOpsState(desired, current, mismatches);
        compareBatteryState(desired, current, mismatches);
        compareSsaidState(desired, current, mismatches);

        root.addProperty("uid", packageInfo.applicationInfo.uid);
        root.add("mismatches", mismatches);
        JsonObject currentResult = objectMember(current, "result");
        if (currentResult != null) root.add("currentSnapshotResult", currentResult.deepCopy());
        ResultCode currentCode = resultCodeFromRecord(current);
        ResultCode code;
        String message = null;
        if (mismatches.size() > 0) {
            code = ResultCode.VERIFY_MISMATCH;
            message = mismatches.size() + " AppState mismatch(es)";
        } else if (currentCode != ResultCode.OK) {
            code = ResultCode.PARTIAL;
            message = "current snapshot was partial";
        } else {
            code = ResultCode.OK;
        }
        setResult(root, code, message);
        return root;
    }

    private static void compareInstallState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        JsonObject expected = objectMember(desired, "installDiagnostics");
        JsonObject actual = objectMember(current, "installDiagnostics");
        if (expected == null || actual == null) return;
        compareScalar(mismatches, "installDiagnostics.versionCode", expected, actual, "versionCode", false);
        compareScalar(mismatches, "installDiagnostics.signingSha256", expected, actual, "signingSha256", false);
        compareScalar(mismatches, "installDiagnostics.splitCount", expected, actual, "splitCount", false);
    }

    private static void comparePermissionState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        Map<String, JsonObject> expected = indexArrayByString(desired.getAsJsonArray("permissions"), "name");
        Map<String, JsonObject> actual = indexArrayByString(current.getAsJsonArray("permissions"), "name");
        int mask = permissionFlagRestoreMask();
        for (Map.Entry<String, JsonObject> entry : expected.entrySet()) {
            String name = entry.getKey();
            JsonObject e = entry.getValue();
            int op = intMember(e, "appOp", AppOpsManagerHidden.OP_NONE);
            boolean runtime = booleanMember(e, "runtime", false);
            boolean legacySpecialOrNonSnapshot = isSpecialAccessOp(op)
                    || (runtime && !isSnapshotPermissionName(name));
            JsonObject a = actual.get(name);
            if (a == null) {
                if (legacySpecialOrNonSnapshot) {
                    // Old app_details can carry special-access/install-time permissions in
                    // the permissions array. New schema intentionally emits those through
                    // specialAccess/other AppOps or omits non-restorable grant rows.
                    continue;
                }
                addMismatch(mismatches, "permissions." + name, e, null, "missing permission record");
                continue;
            }
            if (!legacySpecialOrNonSnapshot) {
                compareScalar(mismatches, "permissions." + name + ".granted", e, a, "granted", false);
                if (e.has("flags")) {
                    int ef = intMember(e, "flags", 0) & mask;
                    int af = intMember(a, "flags", 0) & mask;
                    if (ef != af) addMismatch(mismatches, "permissions." + name + ".flags", ef, af, "restorable flag mask mismatch");
                }
            }
            if (op != AppOpsManagerHidden.OP_NONE && !isSpecialAccessOp(op)) {
                if (runtime && !legacySpecialOrNonSnapshot) {
                    compareEffectiveOpState(mismatches, "permissions." + name + ".appOp",
                            e, a, "appOpMode");
                } else {
                    compareOpState(mismatches, "permissions." + name + ".appOp", e, a, "appOpMode");
                }
            }
        }
    }

    private static void compareSpecialAccessState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        JsonObject expected = desired.getAsJsonObject("specialAccess");
        JsonObject actual = current.getAsJsonObject("specialAccess");
        for (Map.Entry<String, JsonElement> entry : expected.entrySet()) {
            if (!entry.getValue().isJsonObject()) continue;
            JsonObject e = entry.getValue().getAsJsonObject();
            if (!booleanMember(e, "supported", true)
                    || !booleanMember(e, "requested", false)) continue;
            JsonObject a = objectMember(actual, entry.getKey());
            if (a == null) {
                addMismatch(mismatches, "specialAccess." + entry.getKey(), e, null, "missing special access record");
                continue;
            }
            compareOpState(mismatches, "specialAccess." + entry.getKey(), e, a, "mode");
        }
    }

    private static void compareOtherAppOpsState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        Map<Integer, JsonObject> expected = indexArrayByInt(desired.getAsJsonArray("otherAppOps"), "op");
        Map<Integer, JsonObject> actual = indexArrayByInt(current.getAsJsonArray("otherAppOps"), "op");
        for (Map.Entry<Integer, JsonObject> entry : expected.entrySet()) {
            JsonObject e = entry.getValue();
            JsonObject a = actual.get(entry.getKey());
            if (a == null) {
                // getOpsForPackage() only returns AppOps that have an explicit non-default
                // package record on many Android builds.  If the canonical backup expected
                // a pure default state (packageMode/default, uidMode/null or default,
                // effective mode/default), the missing row is semantically identical to
                // MODE_DEFAULT and must not fail verify.  This hit op=119
                // android:access_restricted_settings after restore: setting it to default
                // removed the row, which is the correct platform representation.
                if (isDefaultAppOpRecord(e, "mode")) continue;
                addMismatch(mismatches, "otherAppOps." + entry.getKey(), e, null, "missing AppOp record");
                continue;
            }
            compareOpState(mismatches, "otherAppOps." + entry.getKey(), e, a, "mode");
        }
    }

    private static void compareBatteryState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        JsonObject expected = desired.getAsJsonObject("batterySettings");
        JsonObject actual = current.getAsJsonObject("batterySettings");
        for (String key : Arrays.asList("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND")) {
            JsonObject e = objectMember(expected, key);
            if (e == null || !booleanMember(e, "supported", true)) continue;
            JsonObject a = objectMember(actual, key);
            if (a == null) {
                addMismatch(mismatches, "batterySettings." + key, e, null, "missing battery AppOp record");
                continue;
            }
            compareOpState(mismatches, "batterySettings." + key, e, a, "mode");
        }
        compareScalar(mismatches, "batterySettings.deviceidleWhitelist", expected, actual,
                "deviceidleWhitelist", false);
    }

    private static void compareSsaidState(JsonObject desired, JsonObject current, JsonArray mismatches) {
        if (!desired.has("ssaid") || desired.get("ssaid").isJsonNull()) return;
        JsonElement expected = desired.get("ssaid");
        JsonElement actual = current.has("ssaid") ? current.get("ssaid") : null;
        if (!jsonElementEquals(expected, actual)) {
            addMismatch(mismatches, "ssaid", expected, actual, "SSAID mismatch");
        }
    }

    private static void compareEffectiveOpState(JsonArray mismatches, String path,
                                                JsonObject expected, JsonObject actual,
                                                String effectiveField) {
        int expectedMode = intMember(expected, effectiveField, AppOpsManagerHidden.MODE_DEFAULT);
        int actualMode = intMember(actual, effectiveField, AppOpsManagerHidden.MODE_DEFAULT);
        if (!modeEquivalent(expectedMode, actualMode)) {
            addMismatch(mismatches, path + "." + effectiveField, expectedMode, actualMode,
                    "effective mode mismatch");
        }
    }

    private static void compareOpState(JsonArray mismatches, String path, JsonObject expected,
                                       JsonObject actual, String effectiveField) {
        int op = intMember(expected, "op", intMember(expected, "appOp", AppOpsManagerHidden.OP_NONE));
        boolean packageCompared = false;
        boolean packageOk = true;
        boolean uidCompared = false;
        boolean uidOk = true;
        if (expected.has("packageMode") && !expected.get("packageMode").isJsonNull()) {
            packageCompared = true;
            Integer e = nullableIntMember(expected, "packageMode");
            Integer a = nullableIntMember(actual, "packageMode");
            packageOk = nullableModeEquivalent(e, a);
            if (!packageOk) {
                addMismatch(mismatches, path + ".packageMode", e, a, "package mode mismatch");
            }
        }
        if (expected.has("uidMode") && !expected.get("uidMode").isJsonNull()) {
            uidCompared = true;
            Integer e = nullableIntMember(expected, "uidMode");
            Integer a = nullableIntMember(actual, "uidMode");
            uidOk = nullableModeEquivalent(e, a);
            if (!uidOk) {
                addMismatch(mismatches, path + ".uidMode", e, a, "uid mode mismatch");
            }
        }
        // Some Android 15/16 vendor builds report OP_START_FOREGROUND's effective
        // unsafeCheckOpNoThrow() result as MODE_DEFAULT even after the package-scoped
        // override was correctly written and can be read back from getOpsForPackage().
        // For such ops, the restorable state is the explicit package/uid scope; the
        // effective value is diagnostic only and must not fail restore/verify.
        if (isEffectiveModeAdvisory(op) && (packageCompared || uidCompared) && packageOk && uidOk) {
            return;
        }
        compareEffectiveOpState(mismatches, path, expected, actual, effectiveField);
    }

    private static void compareScalar(JsonArray mismatches, String path, JsonObject expected,
                                      JsonObject actual, String key, boolean mode) {
        if (expected == null || !expected.has(key)) return;
        JsonElement e = expected.get(key);
        JsonElement a = actual != null && actual.has(key) ? actual.get(key) : null;
        boolean equal;
        if (mode && e != null && !e.isJsonNull() && a != null && !a.isJsonNull()) {
            equal = modeEquivalent(e.getAsInt(), a.getAsInt());
        } else {
            equal = jsonElementEquals(e, a);
        }
        if (!equal) addMismatch(mismatches, path, e, a, "value mismatch");
    }

    private static void addMismatch(JsonArray mismatches, String path, Object expected,
                                    Object actual, String message) {
        JsonObject item = new JsonObject();
        item.addProperty("path", path);
        addJsonValue(item, "expected", expected);
        addJsonValue(item, "actual", actual);
        item.addProperty("message", message);
        setResult(item, ResultCode.VERIFY_MISMATCH, message);
        mismatches.add(item);
    }

    private static void addJsonValue(JsonObject object, String key, Object value) {
        if (value == null) {
            addJsonNull(object, key);
        } else if (value instanceof JsonElement) {
            object.add(key, ((JsonElement) value).deepCopy());
        } else if (value instanceof Number) {
            object.addProperty(key, (Number) value);
        } else if (value instanceof Boolean) {
            object.addProperty(key, (Boolean) value);
        } else {
            object.addProperty(key, String.valueOf(value));
        }
    }

    private static boolean jsonElementEquals(JsonElement first, JsonElement second) {
        if (first == null || first.isJsonNull()) return second == null || second.isJsonNull();
        if (second == null || second.isJsonNull()) return false;
        if (first.equals(second) || first.toString().equals(second.toString())) return true;
        if (first.isJsonPrimitive() && second.isJsonPrimitive()) {
            try {
                java.math.BigDecimal a = first.getAsBigDecimal();
                java.math.BigDecimal b = second.getAsBigDecimal();
                return a.compareTo(b) == 0;
            } catch (Throwable ignored) {
            }
        }
        return false;
    }

    private static Map<String, JsonObject> indexArrayByString(JsonArray array, String key) {
        Map<String, JsonObject> out = new LinkedHashMap<>();
        if (array == null) return out;
        for (JsonElement element : array) {
            if (!element.isJsonObject()) continue;
            JsonObject object = element.getAsJsonObject();
            String value = stringMember(object, key);
            if (!value.isEmpty()) out.put(value, object);
        }
        return out;
    }

    private static Map<Integer, JsonObject> indexArrayByInt(JsonArray array, String key) {
        Map<Integer, JsonObject> out = new LinkedHashMap<>();
        if (array == null) return out;
        for (JsonElement element : array) {
            if (!element.isJsonObject()) continue;
            JsonObject object = element.getAsJsonObject();
            int value = intMember(object, key, AppOpsManagerHidden.OP_NONE);
            if (value != AppOpsManagerHidden.OP_NONE) out.put(value, object);
        }
        return out;
    }

    private static Set<Integer> collectExpectedOps(JsonObject desired) {
        Set<Integer> out = new LinkedHashSet<>();
        JsonArray permissions = desired.getAsJsonArray("permissions");
        if (permissions != null) {
            for (JsonElement element : permissions) {
                if (!element.isJsonObject()) continue;
                addExpectedOp(out, intMember(element.getAsJsonObject(), "appOp", AppOpsManagerHidden.OP_NONE));
            }
        }
        JsonObject special = desired.getAsJsonObject("specialAccess");
        if (special != null) {
            for (Map.Entry<String, JsonElement> entry : special.entrySet()) {
                if (entry.getValue().isJsonObject()) {
                    JsonObject state = entry.getValue().getAsJsonObject();
                    if (booleanMember(state, "supported", true)
                            && booleanMember(state, "requested", false)) {
                        addExpectedOp(out, intMember(state, "op", AppOpsManagerHidden.OP_NONE));
                    }
                }
            }
        }
        JsonArray other = desired.getAsJsonArray("otherAppOps");
        if (other != null) {
            for (JsonElement element : other) {
                if (element.isJsonObject()) addExpectedOp(out, intMember(element.getAsJsonObject(), "op", AppOpsManagerHidden.OP_NONE));
            }
        }
        JsonObject battery = desired.getAsJsonObject("batterySettings");
        if (battery != null) {
            for (String key : Arrays.asList("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND")) {
                JsonObject state = objectMember(battery, key);
                if (state != null) addExpectedOp(out, intMember(state, "op", AppOpsManagerHidden.OP_NONE));
            }
        }
        return out;
    }

    private static void addExpectedOp(Set<Integer> out, int op) {
        if (op != AppOpsManagerHidden.OP_NONE && op >= 0) out.add(op);
    }

    private static boolean modeEquivalent(int expected, int actual) {
        return expected == actual || equivalentAllowedMode(actual, expected);
    }

    private static boolean nullableModeEquivalent(Integer expected, Integer actual) {
        if (expected == null || expected == AppOpsManagerHidden.MODE_DEFAULT) {
            return actual == null || actual == AppOpsManagerHidden.MODE_DEFAULT;
        }
        if (actual == null) return false;
        return modeEquivalent(expected, actual);
    }

    private static boolean isDefaultAppOpRecord(JsonObject object, String effectiveField) {
        if (object == null) return true;
        Integer packageMode = nullableIntMember(object, "packageMode");
        Integer uidMode = nullableIntMember(object, "uidMode");
        int effective = intMember(object, effectiveField, AppOpsManagerHidden.MODE_DEFAULT);
        return nullableModeEquivalent(AppOpsManagerHidden.MODE_DEFAULT, packageMode)
                && nullableModeEquivalent(AppOpsManagerHidden.MODE_DEFAULT, uidMode)
                && modeEquivalent(AppOpsManagerHidden.MODE_DEFAULT, effective);
    }

    private static Integer nullableIntMember(JsonObject object, String name) {
        try {
            if (object == null || !object.has(name) || object.get(name).isJsonNull()) return null;
            return object.get(name).getAsInt();
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean booleanMember(JsonObject object, String name, boolean fallback) {
        try {
            if (object == null || !object.has(name) || object.get(name).isJsonNull()) return fallback;
            return object.get(name).getAsBoolean();
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    private static int permissionFlagRestoreMask() {
        int mask = 0;
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_USER_SET", 1 << 0);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_USER_FIXED", 1 << 1);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_REVIEW_REQUIRED", 1 << 6);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_REVOKE_WHEN_REQUESTED", 1 << 14);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_AUTO_REVOKED", 1 << 15);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_ONE_TIME", 1 << 16);
        mask |= PermissionCompat.packageManagerFlag("FLAG_PERMISSION_SELECTED_LOCATION_ACCURACY", 1 << 19);
        return mask;
    }

    private static void setDeviceIdleWhitelist(String packageName, boolean enabled) throws Exception {
        Set<String> current = getDeviceIdleWhitelist();
        if (current.contains(packageName) == enabled) return;
        Throwable serviceFailure = null;
        try {
            Object service = HiddenApiServices.deviceIdle();
            if (enabled) {
                HiddenApiReflection.callRequired(service,
                        new HiddenApiReflection.Call("addPowerSaveWhitelistApp", packageName));
            } else {
                HiddenApiReflection.callRequired(service,
                        new HiddenApiReflection.Call("removePowerSaveWhitelistApp", packageName));
            }
            return;
        } catch (Throwable e) {
            serviceFailure = e;
        }
        String safePackage = packageName == null ? "" : packageName.replaceAll("[^A-Za-z0-9._-]", "");
        if (safePackage.isEmpty()) throw new IllegalArgumentException("invalid package for deviceidle whitelist");
        String prefix = enabled ? "+" : "-";
        int rc = runShellCommand("cmd deviceidle whitelist " + prefix + safePackage);
        if (rc != 0) {
            int fallbackRc = runShellCommand("dumpsys deviceidle whitelist " + prefix + safePackage);
            if (fallbackRc != 0) {
                if (serviceFailure instanceof Exception) throw (Exception) serviceFailure;
                throw new IllegalStateException("deviceidle whitelist update failed rc=" + rc + "/" + fallbackRc,
                        serviceFailure);
            }
        }
    }

    private static int runShellCommand(String command) throws Exception {
        ProcessBuilder builder = new ProcessBuilder("sh", "-c", command);
        builder.redirectErrorStream(true);
        Process process = builder.start();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            while (reader.readLine() != null) {
                // Drain output so a full pipe cannot deadlock waitFor().
            }
        }
        return process.waitFor();
    }

    static List<String> parsePackageLines(String text) {
        List<String> out = new ArrayList<>();
        if (text == null) return out;
        for (String line : text.split("\\r?\\n")) {
            String value = line.trim();
            if (value.isEmpty() || value.startsWith("#")) continue;
            for (String token : value.split("\\s+")) {
                if (!token.isEmpty()) out.add(token);
            }
        }
        return dedupePackages(out);
    }

    private static JsonObject snapshotPackage(PackageManager realPm, PackageManagerHidden pmHidden,
                                              AppOpsManagerHidden appOps, Set<String> idleWhitelist,
                                              UserHandle user, int userId, String packageName,
                                              GooglePackageSnapshot playStore,
                                              GooglePackageSnapshot playServices) throws Exception {
        PackageInfo packageInfo = pmHidden.getPackageInfoAsUser(
                packageName, snapshotPackageFlags(), userId);
        JsonObject root = baseRecord("snapshot", userId, packageName);
        JsonArray errors = new JsonArray();
        ResultCode code = ResultCode.OK;

        JsonObject packageObject = new JsonObject();
        packageObject.addProperty("uid", packageInfo.applicationInfo.uid);
        packageObject.addProperty("label", safeLabel(realPm, packageInfo.applicationInfo));
        packageObject.addProperty("versionCode", longVersionCode(packageInfo));
        packageObject.addProperty("versionName", packageInfo.versionName == null ? "" : packageInfo.versionName);
        packageObject.addProperty("systemApp", (packageInfo.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0);
        String installer = null;
        try {
            installer = realPm.getInstallerPackageName(packageName);
        } catch (Throwable e) {
            errors.add(errorObject("installer", ResultCode.PARTIAL, failureMessage(e)));
            code = ResultCode.PARTIAL;
        }
        if (installer == null) addJsonNull(packageObject, "installer");
        else packageObject.addProperty("installer", installer);
        root.add("package", packageObject);
        try {
            root.add("installDiagnostics", collectInstallDiagnostics(
                    realPm, packageInfo, installer, playStore, playServices));
        } catch (Throwable e) {
            root.add("installDiagnostics", new JsonObject());
            errors.add(errorObject("installDiagnostics", classifyThrowable(e), failureMessage(e)));
            code = ResultCode.PARTIAL;
        }

        Map<Integer, Integer> rawOps = readPackageOps(appOps, packageInfo.applicationInfo.uid, packageName);
        Set<Integer> handledOps = new HashSet<>();
        Set<Integer> specialManagedOps = collectRequestedSpecialAccessOps(packageInfo);
        handledOps.addAll(specialManagedOps);
        try {
            root.add("permissions", collectPermissions(realPm, pmHidden, appOps, user, packageInfo,
                    rawOps, handledOps, specialManagedOps));
        } catch (Throwable e) {
            root.add("permissions", new JsonArray());
            errors.add(errorObject("permissions", classifyThrowable(e), failureMessage(e)));
            code = ResultCode.PARTIAL;
        }

        JsonObject specialAccess;
        try {
            specialAccess = collectSpecialAccess(appOps, packageInfo);
            root.add("specialAccess", specialAccess);
            for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) {
                int op = resolveOp(descriptor.publicName);
                if (op != AppOpsManagerHidden.OP_NONE) handledOps.add(op);
            }
        } catch (Throwable e) {
            root.add("specialAccess", new JsonObject());
            errors.add(errorObject("specialAccess", classifyThrowable(e), failureMessage(e)));
            code = ResultCode.PARTIAL;
        }

        try {
            root.add("batterySettings", collectBatterySettings(appOps, packageInfo, idleWhitelist));
            int runInBackground = resolveOp("android:run_in_background");
            int runAnyInBackground = resolveOp("android:run_any_in_background");
            if (runInBackground != AppOpsManagerHidden.OP_NONE) {
                handledOps.add(runInBackground);
                rawOps.remove(runInBackground);
            }
            if (runAnyInBackground != AppOpsManagerHidden.OP_NONE) {
                handledOps.add(runAnyInBackground);
                rawOps.remove(runAnyInBackground);
            }
        } catch (Throwable e) {
            root.add("batterySettings", new JsonObject());
            errors.add(errorObject("batterySettings", classifyThrowable(e), failureMessage(e)));
            code = ResultCode.PARTIAL;
        }

        root.add("otherAppOps", collectOtherAppOps(appOps, packageInfo, rawOps, handledOps));

        try {
            String ssaid = SsaidUtil.readSsaidValue(userId, packageName, pmHidden);
            if (ssaid == null) addJsonNull(root, "ssaid");
            else root.addProperty("ssaid", ssaid);
        } catch (Throwable e) {
            addJsonNull(root, "ssaid");
            errors.add(errorObject("ssaid", classifyThrowable(e), failureMessage(e)));
            code = ResultCode.PARTIAL;
        }

        // Canonical schema v2 contract: every AppOp-bearing record always exposes both
        // packageMode and uidMode, even when one scope is unavailable (explicit JSON null).
        enforceScopedOpContract(root);
        // Fail the package snapshot before serialization if the declared scoped-AppOps
        // contract is incomplete. This prevents capability/output drift in release builds.
        validateScopedOpContract(root);
        if (errors.size() > 0) root.add("errors", errors);
        setResult(root, code, code == ResultCode.PARTIAL ? "one or more optional fields failed" : null);
        return root;
    }

    private static JsonArray collectPermissions(PackageManager realPm, PackageManagerHidden pmHidden,
                                                AppOpsManagerHidden appOps, UserHandle user,
                                                PackageInfo packageInfo, Map<Integer, Integer> rawOps,
                                                Set<Integer> handledOps, Set<Integer> specialManagedOps) {
        JsonArray out = new JsonArray();
        String[] requested = packageInfo.requestedPermissions;
        int[] requestedFlags = packageInfo.requestedPermissionsFlags;
        if (requested == null) return out;
        for (int i = 0; i < requested.length; i++) {
            String permissionName = requested[i];
            JsonObject item = new JsonObject();
            item.addProperty("name", permissionName);
            boolean granted = requestedFlags != null && i < requestedFlags.length
                    && (requestedFlags[i] & PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0;
            item.addProperty("granted", granted);
            try {
                item.addProperty("flags", pmHidden.getPermissionFlags(permissionName, packageInfo.packageName, user));
            } catch (Throwable e) {
                item.addProperty("flags", 0);
                item.addProperty("flagsError", failureMessage(e));
            }
            int protection = -1;
            int protectionFlags = 0;
            try {
                int[] info = permissionProtection(realPm, permissionName);
                protection = info[0];
                protectionFlags = info[1];
            } catch (Throwable ignored) {
            }
            item.addProperty("protection", protection);
            item.addProperty("protectionFlags", protectionFlags);
            item.addProperty("runtime", protection == PermissionInfo.PROTECTION_DANGEROUS);
            item.addProperty("development", (protectionFlags & PermissionInfo.PROTECTION_FLAG_DEVELOPMENT) != 0);
            int op = AppOpsManagerHidden.OP_NONE;
            try {
                op = AppOpsManagerHidden.permissionToOpCode(permissionName);
            } catch (Throwable ignored) {
            }
            boolean managedBySpecialAccess = op != AppOpsManagerHidden.OP_NONE
                    && specialManagedOps.contains(op);
            item.addProperty("appOp", managedBySpecialAccess ? AppOpsManagerHidden.OP_NONE : op);
            if (managedBySpecialAccess) {
                item.addProperty("appOpManagedBy", "specialAccess");
            } else if (op != AppOpsManagerHidden.OP_NONE) {
                addScopedOpState(item, appOps, op, packageInfo.applicationInfo.uid,
                        packageInfo.packageName, "appOpMode");
                handledOps.add(op);
                rawOps.remove(op);
            }
            if ((!managedBySpecialAccess && op != AppOpsManagerHidden.OP_NONE)
                    || protection == PermissionInfo.PROTECTION_DANGEROUS
                    || (!managedBySpecialAccess
                    && (protectionFlags & PermissionInfo.PROTECTION_FLAG_DEVELOPMENT) != 0)) {
                out.add(item);
            }
        }
        return out;
    }

    private static Set<Integer> collectRequestedSpecialAccessOps(PackageInfo packageInfo) {
        Set<Integer> out = new HashSet<>();
        for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) {
            if (!isSpecialAccessRequested(descriptor, packageInfo)) continue;
            int op = resolveOp(descriptor.publicName);
            if (op != AppOpsManagerHidden.OP_NONE) out.add(op);
        }
        return out;
    }

    private static boolean isManagedBySpecialAccess(JsonObject desired, int op) {
        JsonObject special = objectMember(desired, "specialAccess");
        if (special == null || op == AppOpsManagerHidden.OP_NONE) return false;
        for (Map.Entry<String, JsonElement> entry : special.entrySet()) {
            if (!entry.getValue().isJsonObject()) continue;
            JsonObject state = entry.getValue().getAsJsonObject();
            if (!booleanMember(state, "supported", true)
                    || !booleanMember(state, "requested", false)) continue;
            if (intMember(state, "op", AppOpsManagerHidden.OP_NONE) == op) return true;
        }
        return false;
    }

    private static boolean isSpecialAccessOp(int op) {
        if (op == AppOpsManagerHidden.OP_NONE) return false;
        for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) {
            if (resolveOp(descriptor.publicName) == op) return true;
        }
        return false;
    }

    private static boolean isSnapshotPermissionName(String permissionName) {
        if (permissionName == null) return false;
        try {
            int[] protection = permissionProtection(runtimeServices().packageManager, permissionName);
            int base = protection[0];
            int flags = protection[1];
            return base == PermissionInfo.PROTECTION_DANGEROUS
                    || (flags & PermissionInfo.PROTECTION_FLAG_DEVELOPMENT) != 0;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean isChangeablePermissionGrant(PackageManager pm, String permissionName,
                                                       boolean declaredRuntime, boolean declaredDevelopment) {
        try {
            int[] protection = permissionProtection(pm, permissionName);
            int base = protection[0];
            int flags = protection[1];
            return base == PermissionInfo.PROTECTION_DANGEROUS
                    || (flags & PermissionInfo.PROTECTION_FLAG_DEVELOPMENT) != 0;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static JsonObject collectSpecialAccess(AppOpsManagerHidden appOps, PackageInfo packageInfo) {
        JsonObject out = new JsonObject();
        for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) {
            JsonObject item = new JsonObject();
            int op = resolveOp(descriptor.publicName);
            boolean supported = op != AppOpsManagerHidden.OP_NONE;
            boolean requested = isSpecialAccessRequested(descriptor, packageInfo);
            item.addProperty("publicName", descriptor.publicName);
            if (descriptor.manifestPermission == null) addJsonNull(item, "manifestPermission");
            else item.addProperty("manifestPermission", descriptor.manifestPermission);
            item.addProperty("requested", requested);
            item.addProperty("supported", supported);
            item.addProperty("op", op);
            item.addProperty("source", "appop");
            if (supported) {
                int uid = packageInfo.applicationInfo.uid;
                Integer packageMode = AppOpsCompat.tryGetPackageModeRaw(appOps, op, uid, packageInfo.packageName);
                Integer uidMode = AppOpsCompat.tryGetUidModeRaw(appOps, op, uid, AppStateEngine::publicOpName);
                int mode = getEffectiveOpMode(appOps, op, uid, packageInfo.packageName);
                if (packageMode == null) addJsonNull(item, "packageMode");
                else item.addProperty("packageMode", packageMode);
                if (uidMode == null) addJsonNull(item, "uidMode");
                else item.addProperty("uidMode", uidMode);
                String scope = "default";
                if (packageMode != null && packageMode != AppOpsManagerHidden.MODE_DEFAULT) scope = "package";
                else if (uidMode != null && uidMode != AppOpsManagerHidden.MODE_DEFAULT) scope = "uid";
                item.addProperty("scope", scope);
                item.addProperty("mode", mode);
                item.addProperty("modeName", modeName(mode));
                item.addProperty("allowed", allowedMode(mode));
            } else {
                addJsonNull(item, "packageMode");
                addJsonNull(item, "uidMode");
                item.addProperty("scope", "unsupported");
                item.addProperty("mode", AppOpsManagerHidden.MODE_DEFAULT);
                item.addProperty("modeName", "unsupported");
                item.addProperty("allowed", false);
            }
            out.add(descriptor.key, item);
        }
        return out;
    }

    private static JsonArray collectOtherAppOps(AppOpsManagerHidden appOps, PackageInfo packageInfo,
                                                Map<Integer, Integer> rawOps, Set<Integer> handledOps) {
        JsonArray out = new JsonArray();
        List<Map.Entry<Integer, Integer>> entries = new ArrayList<>(rawOps.entrySet());
        entries.sort(Comparator.comparingInt(e -> e.getKey()));
        for (Map.Entry<Integer, Integer> entry : entries) {
            if (handledOps.contains(entry.getKey())) continue;
            JsonObject item = new JsonObject();
            item.addProperty("op", entry.getKey());
            item.addProperty("publicName", publicOpName(entry.getKey()));
            addScopedOpState(item, appOps, entry.getKey(), packageInfo.applicationInfo.uid,
                    packageInfo.packageName, "mode");
            out.add(item);
        }
        return out;
    }

    private static JsonObject collectBatterySettings(AppOpsManagerHidden appOps, PackageInfo packageInfo,
                                                     Set<String> idleWhitelist) {
        JsonObject out = new JsonObject();
        out.add("RUN_IN_BACKGROUND", appOpState(appOps, packageInfo, resolveOp("android:run_in_background")));
        out.add("RUN_ANY_IN_BACKGROUND", appOpState(appOps, packageInfo, resolveOp("android:run_any_in_background")));
        out.addProperty("deviceidleWhitelist", idleWhitelist.contains(packageInfo.packageName));
        return out;
    }

    private static JsonObject appOpState(AppOpsManagerHidden appOps, PackageInfo packageInfo, int op) {
        JsonObject item = new JsonObject();
        item.addProperty("op", op);
        item.addProperty("supported", op != AppOpsManagerHidden.OP_NONE);
        if (op == AppOpsManagerHidden.OP_NONE) {
            addJsonNull(item, "packageMode");
            addJsonNull(item, "uidMode");
            item.addProperty("scope", "unsupported");
            item.addProperty("mode", AppOpsManagerHidden.MODE_DEFAULT);
            item.addProperty("modeName", "unsupported");
            item.addProperty("allowed", false);
        } else {
            addScopedOpState(item, appOps, op, packageInfo.applicationInfo.uid,
                    packageInfo.packageName, "mode");
        }
        return item;
    }

    private static void addScopedOpState(JsonObject item, AppOpsManagerHidden appOps, int op,
                                         int uid, String packageName, String modeField) {
        Integer packageMode = AppOpsCompat.tryGetPackageModeRaw(appOps, op, uid, packageName);
        Integer uidMode = AppOpsCompat.tryGetUidModeRaw(appOps, op, uid, AppStateEngine::publicOpName);
        int mode = getEffectiveOpMode(appOps, op, uid, packageName);
        if (packageMode == null) addJsonNull(item, "packageMode");
        else item.addProperty("packageMode", packageMode);
        if (uidMode == null) addJsonNull(item, "uidMode");
        else item.addProperty("uidMode", uidMode);
        String scope = "default";
        if (packageMode != null && packageMode != AppOpsManagerHidden.MODE_DEFAULT) scope = "package";
        else if (uidMode != null && uidMode != AppOpsManagerHidden.MODE_DEFAULT) scope = "uid";
        item.addProperty("scope", scope);
        item.addProperty(modeField, mode);
        item.addProperty(modeField + "Name", modeName(mode));
        item.addProperty("allowed", allowedMode(mode));
    }

    private static void addJsonNull(JsonObject object, String name) {
        object.add(name, JsonNull.INSTANCE);
    }

    private static void ensureNullableMember(JsonObject object, String name) {
        if (object != null && !object.has(name)) addJsonNull(object, name);
    }

    private static void ensureScopedOpFields(JsonObject object) {
        if (object == null) return;
        ensureNullableMember(object, "packageMode");
        ensureNullableMember(object, "uidMode");
    }

    private static void enforceScopedOpContract(JsonObject root) {
        JsonArray permissions = root.getAsJsonArray("permissions");
        if (permissions != null) {
            for (JsonElement element : permissions) {
                if (!element.isJsonObject()) continue;
                JsonObject item = element.getAsJsonObject();
                if (intMember(item, "appOp", AppOpsManagerHidden.OP_NONE) != AppOpsManagerHidden.OP_NONE) {
                    ensureScopedOpFields(item);
                }
            }
        }
        JsonObject specialAccess = objectMember(root, "specialAccess");
        if (specialAccess != null) {
            for (Map.Entry<String, JsonElement> entry : specialAccess.entrySet()) {
                if (entry.getValue().isJsonObject()) ensureScopedOpFields(entry.getValue().getAsJsonObject());
            }
        }
        JsonArray otherAppOps = root.getAsJsonArray("otherAppOps");
        if (otherAppOps != null) {
            for (JsonElement element : otherAppOps) {
                if (element.isJsonObject()) ensureScopedOpFields(element.getAsJsonObject());
            }
        }
        JsonObject battery = objectMember(root, "batterySettings");
        if (battery != null) {
            for (String key : Arrays.asList("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND")) {
                JsonObject item = objectMember(battery, key);
                if (item != null) ensureScopedOpFields(item);
            }
        }
    }

    private static void validateScopedOpObject(JsonObject object, String path) {
        if (object == null) throw new IllegalArgumentException(path + " must be an object");
        if (!object.has("packageMode")) throw new IllegalArgumentException(path + ".packageMode is missing");
        if (!object.has("uidMode")) throw new IllegalArgumentException(path + ".uidMode is missing");
        if (!object.has("scope")) throw new IllegalArgumentException(path + ".scope is missing");
        if (!object.has("mode") && !object.has("appOpMode")) {
            throw new IllegalArgumentException(path + ".effective mode is missing");
        }
    }

    private static void validateScopedOpContract(JsonObject root) {
        JsonArray permissions = root.getAsJsonArray("permissions");
        if (permissions != null) {
            int permissionIndex = 0;
            for (JsonElement element : permissions) {
                if (!element.isJsonObject()) {
                    throw new IllegalArgumentException("permissions[" + permissionIndex + "] must be an object");
                }
                JsonObject item = element.getAsJsonObject();
                if (intMember(item, "appOp", AppOpsManagerHidden.OP_NONE) != AppOpsManagerHidden.OP_NONE) {
                    validateScopedOpObject(item, "permissions[" + permissionIndex + "]");
                }
                permissionIndex++;
            }
        }
        JsonObject specialAccess = root.getAsJsonObject("specialAccess");
        for (Map.Entry<String, JsonElement> entry : specialAccess.entrySet()) {
            if (!entry.getValue().isJsonObject()) {
                throw new IllegalArgumentException("specialAccess." + entry.getKey() + " must be an object");
            }
            validateScopedOpObject(entry.getValue().getAsJsonObject(), "specialAccess." + entry.getKey());
        }
        JsonArray otherAppOps = root.getAsJsonArray("otherAppOps");
        int appOpIndex = 0;
        for (JsonElement element : otherAppOps) {
            if (!element.isJsonObject()) {
                throw new IllegalArgumentException("otherAppOps[" + appOpIndex + "] must be an object");
            }
            validateScopedOpObject(element.getAsJsonObject(), "otherAppOps[" + appOpIndex + "]");
            appOpIndex++;
        }
        JsonObject battery = root.getAsJsonObject("batterySettings");
        for (String key : Arrays.asList("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND")) {
            if (battery.has(key)) validateScopedOpObject(objectMember(battery, key), "batterySettings." + key);
        }
    }

    private static Map<Integer, Integer> readPackageOps(AppOpsManagerHidden appOps, int uid, String packageName) {
        Map<Integer, Integer> out = new LinkedHashMap<>();
        try {
            List<AppOpsManagerHidden.PackageOps> list = appOps.getOpsForPackage(uid, packageName, null);
            if (list != null && !list.isEmpty() && list.get(0).getOps() != null) {
                for (AppOpsManagerHidden.OpEntry entry : list.get(0).getOps()) {
                    out.put(entry.getOp(), entry.getMode());
                }
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    private static int getOpMode(AppOpsManagerHidden appOps, int op, int uid, String packageName) {
        if (op == AppOpsManagerHidden.OP_NONE) return AppOpsManagerHidden.MODE_DEFAULT;
        try {
            return appOps.unsafeCheckOpRawNoThrow(op, uid, packageName);
        } catch (Throwable ignored) {
        }
        try {
            return appOps.checkOpNoThrow(op, uid, packageName);
        } catch (Throwable ignored) {
        }
        return AppOpsManagerHidden.MODE_DEFAULT;
    }

    private static int getEffectiveOpMode(AppOpsManagerHidden appOps, int op, int uid, String packageName) {
        // unsafeCheckOpRawNoThrow/checkOpNoThrow are suitable for the effective result only.
        // Stored package and uid scopes are captured separately by AppOpsCompat.
        return getOpMode(appOps, op, uid, packageName);
    }

    private static int resolveOp(String publicName) {
        Integer cached = OP_CACHE.get(publicName);
        if (cached != null) return cached;
        int op = AppOpsManagerHidden.OP_NONE;
        try {
            op = AppOpsManagerHidden.strOpToOp(publicName);
        } catch (Throwable ignored) {
        }
        if (op == AppOpsManagerHidden.OP_NONE) {
            try {
                String fieldName = "OP_" + publicName.substring(publicName.indexOf(':') + 1)
                        .toUpperCase(Locale.ROOT);
                Class<?> clazz = HiddenApiReflection.classForNameCached("android.app.AppOpsManager");
                java.lang.reflect.Field field = clazz.getDeclaredField(fieldName);
                field.setAccessible(true);
                op = field.getInt(null);
            } catch (Throwable ignored) {
            }
        }
        OP_CACHE.put(publicName, op);
        return op;
    }

    private static String publicOpName(int op) {
        try {
            String name = AppOpsManagerHidden.opToPublicName(op);
            if (name != null && !name.isEmpty()) return name;
        } catch (Throwable ignored) {
        }
        try {
            String name = AppOpsManagerHidden.opToName(op);
            if (name != null && !name.isEmpty()) return "android:" + name.toLowerCase(Locale.ROOT);
        } catch (Throwable ignored) {
        }
        return "android:op_" + op;
    }

    private static String modeName(int mode) {
        switch (mode) {
            case AppOpsManagerHidden.MODE_ALLOWED: return "allow";
            case AppOpsManagerHidden.MODE_IGNORED: return "ignore";
            case AppOpsManagerHidden.MODE_ERRORED: return "deny";
            case AppOpsManagerHidden.MODE_DEFAULT: return "default";
            case AppOpsManagerHidden.MODE_FOREGROUND: return "foreground";
            default: return String.valueOf(mode);
        }
    }

    private static boolean allowedMode(int mode) {
        return mode == AppOpsManagerHidden.MODE_ALLOWED || mode == AppOpsManagerHidden.MODE_FOREGROUND;
    }

    private static boolean equivalentAllowedMode(int actual, int expected) {
        return allowedMode(actual) && allowedMode(expected);
    }

    private static boolean isSpecialAccessRequested(SpecialAccessDescriptor descriptor, PackageInfo packageInfo) {
        if (descriptor.requirePictureInPictureActivity) {
            if (packageInfo.activities == null) return false;
            for (ActivityInfo activityInfo : packageInfo.activities) {
                if (activityInfo != null
                        && (activityInfo.flags & ActivityInfoHidden.FLAG_SUPPORTS_PICTURE_IN_PICTURE) != 0) {
                    return true;
                }
            }
            return false;
        }
        if (descriptor.manifestPermission == null) return true;
        if (packageInfo.requestedPermissions == null) return false;
        for (String permission : packageInfo.requestedPermissions) {
            if (descriptor.manifestPermission.equals(permission)) return true;
        }
        return false;
    }

    private static int[] permissionProtection(PackageManager pm, String permissionName)
            throws PackageManager.NameNotFoundException {
        int[] cached = PERMISSION_PROTECTION_CACHE.get(permissionName);
        if (cached != null) return cached;
        PermissionInfo info = pm.getPermissionInfo(permissionName, 0);
        int[] value = new int[] {
                info.protectionLevel & 0x0000000f,
                info.protectionLevel & 0xfffffff0
        };
        PERMISSION_PROTECTION_CACHE.put(permissionName, value);
        return value;
    }

    private static Set<String> getDeviceIdleWhitelist() {
        Set<String> result = new HashSet<>();
        try {
            Object service = HiddenApiServices.deviceIdle();
            Object names = HiddenApiReflection.callFirst(service,
                    new HiddenApiReflection.Call("getFullPowerWhitelist"),
                    new HiddenApiReflection.Call("getFullPowerWhitelistExceptIdle"));
            if (names instanceof String[]) {
                result.addAll(Arrays.asList((String[]) names));
                result.remove(null);
                result.remove("");
                return result;
            }
        } catch (Throwable ignored) {
        }
        try {
            Process process = Runtime.getRuntime().exec(new String[]{"sh", "-c", "dumpsys deviceidle whitelist"});
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    for (String token : line.split("[,\\s]+")) {
                        String value = token.trim();
                        if (value.contains(".") && value.matches("[A-Za-z0-9._-]+")) result.add(value);
                    }
                }
            }
            process.waitFor();
        } catch (Throwable ignored) {
        }
        return result;
    }

    private static int snapshotPackageFlags() {
        int flags = PackageManager.GET_PERMISSIONS | PackageManager.GET_ACTIVITIES;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            flags |= PackageManager.GET_SIGNING_CERTIFICATES;
        } else {
            //noinspection deprecation
            flags |= PackageManager.GET_SIGNATURES;
        }
        return flags;
    }

    private static JsonObject collectInstallDiagnostics(PackageManager pm, PackageInfo packageInfo,
                                                        String installerFallback,
                                                        GooglePackageSnapshot playStore,
                                                        GooglePackageSnapshot playServices) {
        JsonObject out = new JsonObject();
        String installing = installerFallback;
        String initiating = null;
        String originating = null;
        String updateOwner = null;
        String packageSource = "null";
        String packageSourceName = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                ? "UNKNOWN" : "UNAVAILABLE_API_LT_30";
        String updateOwnerApi = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
                ? "api34_plus" : "unsupported_pre34";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Object info = HiddenApiReflection.invokeFlexible(pm, "getInstallSourceInfo", packageInfo.packageName);
                installing = firstNonEmpty(safeString(invokeNoArg(info, "getInstallingPackageName")), installerFallback);
                initiating = safeString(invokeNoArg(info, "getInitiatingPackageName"));
                originating = safeString(invokeNoArg(info, "getOriginatingPackageName"));
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    updateOwner = safeString(invokeNoArg(info, "getUpdateOwnerPackageName"));
                }
                Object source = invokeNoArg(info, "getPackageSource");
                if (source instanceof Number) {
                    int value = ((Number) source).intValue();
                    packageSource = String.valueOf(value);
                    packageSourceName = packageSourceToName(value);
                }
            } catch (Throwable ignored) {
            }
        }
        addNullable(out, "installer", installerFallback);
        addNullable(out, "installing", installing);
        addNullable(out, "initiating", initiating);
        addNullable(out, "originating", originating);
        addNullable(out, "updateOwner", updateOwner);
        out.addProperty("updateOwnerApi", updateOwnerApi);
        out.addProperty("packageSource", packageSource);
        out.addProperty("packageSourceName", packageSourceName);
        long versionCode = longVersionCode(packageInfo);
        String signingSha256 = signingSha256(packageInfo);
        int splitCount = packageInfo.splitNames == null ? 0 : packageInfo.splitNames.length;
        out.addProperty("versionCode", versionCode);
        out.addProperty("versionName", packageInfo.versionName == null ? "" : packageInfo.versionName);
        out.addProperty("signingSha256", signingSha256);
        out.addProperty("splitCount", splitCount);
        addNullable(out, "sourceDir", packageInfo.applicationInfo == null ? null : packageInfo.applicationInfo.sourceDir);
        addGooglePackageDiagnostics(out, "playStore", playStore);
        addGooglePackageDiagnostics(out, "playServices", playServices);
        addPlayRestoreRisks(out, installerFallback, updateOwner, versionCode, signingSha256, splitCount,
                playStore == null ? "missing" : playStore.state,
                playServices == null ? "missing" : playServices.state);
        return out;
    }

    private static GooglePackageSnapshot googlePackageSnapshot(
            PackageManager realPm, PackageManagerHidden pmHidden, AppOpsManagerHidden appOps,
            Set<String> idleWhitelist, int userId, String packageName) {
        GooglePackageSnapshot out = new GooglePackageSnapshot();
        try {
            PackageInfo info = pmHidden.getPackageInfoAsUser(packageName, 0, userId);
            if (info == null || info.applicationInfo == null) return out;
            out.state = info.applicationInfo.enabled ? "installed_enabled" : "installed_disabled";
            out.uid = String.valueOf(info.applicationInfo.uid);
            out.versionCode = String.valueOf(longVersionCode(info));
            try {
                out.enabledState = String.valueOf(realPm.getApplicationEnabledSetting(packageName));
            } catch (Throwable ignored) {
                out.enabledState = info.applicationInfo.enabled ? "0" : "unknown";
            }
            int runInBackground = resolveOp("android:run_in_background");
            int runAnyInBackground = resolveOp("android:run_any_in_background");
            if (runInBackground != AppOpsManagerHidden.OP_NONE) {
                out.runInBackgroundMode = String.valueOf(getEffectiveOpMode(
                        appOps, runInBackground, info.applicationInfo.uid, packageName));
            }
            if (runAnyInBackground != AppOpsManagerHidden.OP_NONE) {
                out.runAnyInBackgroundMode = String.valueOf(getEffectiveOpMode(
                        appOps, runAnyInBackground, info.applicationInfo.uid, packageName));
            }
            out.deviceIdleWhitelist = String.valueOf(idleWhitelist != null && idleWhitelist.contains(packageName));
        } catch (Throwable ignored) {
            // Missing or inaccessible Google package remains an explicit "missing" snapshot.
        }
        return out;
    }

    private static void addGooglePackageDiagnostics(JsonObject out, String prefix,
                                                    GooglePackageSnapshot snapshot) {
        GooglePackageSnapshot value = snapshot == null ? new GooglePackageSnapshot() : snapshot;
        out.addProperty(prefix, value.state);
        out.addProperty(prefix + "EnabledState", value.enabledState);
        out.addProperty(prefix + "Uid", value.uid);
        out.addProperty(prefix + "VersionCode", value.versionCode);
        out.addProperty(prefix + "RunInBackgroundMode", value.runInBackgroundMode);
        out.addProperty(prefix + "RunAnyInBackgroundMode", value.runAnyInBackgroundMode);
        out.addProperty(prefix + "DeviceIdleWhitelist", value.deviceIdleWhitelist);
    }

    private static void addPlayRestoreRisks(JsonObject out, String installer, String updateOwner,
                                            long versionCode, String signingSha256, int splitCount,
                                            String playStoreState, String playServicesState) {
        if (installer == null || installer.isEmpty()) {
            out.addProperty("risk_INSTALLER_NULL", "SET_INSTALLER_IF_PLAY_APP");
        } else if (!"com.android.vending".equals(installer)) {
            out.addProperty("risk_INSTALLER_NOT_PLAY", "SET_INSTALLER_COM_ANDROID_VENDING_IF_NEEDED");
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
                && "com.android.vending".equals(updateOwner)) {
            out.addProperty("risk_UPDATE_OWNER_PLAY_API34_PLUS",
                    "USE_PLAY_UPDATE_OR_REINSTALL_WITH_CORRECT_SESSION");
        }
        if (versionCode <= 0) out.addProperty("risk_VERSION_UNKNOWN", "REINSTALL_CORRECT_APK");
        if (signingSha256 == null || signingSha256.isEmpty() || "null".equals(signingSha256)) {
            out.addProperty("risk_SIGNATURE_UNREADABLE", "REINSTALL_CORRECT_SIGNED_APK");
        }
        if (splitCount > 0) out.addProperty("risk_HAS_SPLITS", "BACKUP_AND_RESTORE_ALL_SPLIT_APKS");
        if (!"installed_enabled".equals(playStoreState)) {
            out.addProperty("risk_PLAY_STORE_NOT_READY", "ENABLE_OR_RESTORE_COM_ANDROID_VENDING");
        }
        if (!"installed_enabled".equals(playServicesState)) {
            out.addProperty("risk_PLAY_SERVICES_NOT_READY", "ENABLE_OR_RESTORE_COM_GOOGLE_ANDROID_GMS");
        }
    }

    private static Object invokeNoArg(Object target, String methodName) {
        if (target == null) return null;
        try {
            return HiddenApiReflection.invokeFlexible(target, methodName);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String safeString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String firstNonEmpty(String first, String second) {
        return first != null && !first.isEmpty() ? first : second;
    }

    private static void addNullable(JsonObject object, String key, String value) {
        if (value == null || value.isEmpty()) addJsonNull(object, key);
        else object.addProperty(key, value);
    }

    private static volatile Map<Integer, String> PACKAGE_SOURCE_NAMES;

    private static String packageSourceToName(int source) {
        Map<Integer, String> map = PACKAGE_SOURCE_NAMES;
        if (map == null) {
            map = new HashMap<>();
            try {
                Class<?> clazz = HiddenApiReflection.classForNameCached("android.content.pm.PackageInstaller");
                for (java.lang.reflect.Field field : clazz.getFields()) {
                    if (field.getName().startsWith("PACKAGE_SOURCE_") && field.getType() == int.class) {
                        map.put(field.getInt(null), field.getName());
                    }
                }
            } catch (Throwable ignored) {
            }
            PACKAGE_SOURCE_NAMES = map;
        }
        String name = map.get(source);
        return name == null ? "UNKNOWN_" + source : name;
    }

    private static String signingSha256(PackageInfo packageInfo) {
        try {
            android.content.pm.Signature[] signatures = null;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && packageInfo.signingInfo != null) {
                signatures = packageInfo.signingInfo.hasMultipleSigners()
                        ? packageInfo.signingInfo.getApkContentsSigners()
                        : packageInfo.signingInfo.getSigningCertificateHistory();
            }
            //noinspection deprecation
            if ((signatures == null || signatures.length == 0) && packageInfo.signatures != null) {
                //noinspection deprecation
                signatures = packageInfo.signatures;
            }
            if (signatures == null || signatures.length == 0) return "null";
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            List<String> hashes = new ArrayList<>();
            for (android.content.pm.Signature signature : signatures) {
                if (signature != null) hashes.add(bytesToHex(digest.digest(signature.toByteArray())));
            }
            return hashes.isEmpty() ? "null" : String.join(",", hashes);
        } catch (Throwable ignored) {
            return "null";
        }
    }

    private static String bytesToHex(byte[] bytes) {
        char[] hex = "0123456789abcdef".toCharArray();
        char[] out = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 0xff;
            out[i * 2] = hex[value >>> 4];
            out[i * 2 + 1] = hex[value & 0x0f];
        }
        return new String(out);
    }

    private static long longVersionCode(PackageInfo info) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return info.getLongVersionCode();
        //noinspection deprecation
        return info.versionCode;
    }

    private static String safeLabel(PackageManager pm, ApplicationInfo info) {
        try {
            CharSequence value = info.loadLabel(pm);
            return value == null ? "" : value.toString().replace('\n', ' ').trim();
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static Map<String, SpecialAccessDescriptor> buildSpecialAccessMap() {
        Map<String, SpecialAccessDescriptor> out = new LinkedHashMap<>();
        for (SpecialAccessDescriptor descriptor : SPECIAL_ACCESS) out.put(descriptor.key, descriptor);
        return Collections.unmodifiableMap(out);
    }

    private static void addCapability(JsonArray array, String name, boolean enabled, boolean critical, String protocol) {
        JsonObject item = new JsonObject();
        item.addProperty("name", name);
        item.addProperty("enabled", enabled);
        item.addProperty("critical", critical);
        item.addProperty("protocol", protocol);
        array.add(item);
    }

    private static JsonObject baseRecord(String recordType, int userId, String packageName) {
        JsonObject root = new JsonObject();
        root.addProperty("schemaVersion", SCHEMA_VERSION);
        root.addProperty("engineVersion", ENGINE_VERSION);
        root.addProperty("dexVersion", HiddenApiUtil.VERSION);
        root.addProperty("recordType", recordType);
        root.addProperty("userId", userId);
        root.addProperty("packageName", packageName == null ? "" : packageName);
        return root;
    }

    private static JsonObject packageErrorRecord(String recordType, int userId, String packageName,
                                                 ResultCode code, String message) {
        JsonObject root = baseRecord(recordType, userId, packageName);
        setResult(root, code, message);
        return root;
    }

    private static JsonObject summaryRecord(String command, ResultCode code, int total, int ok,
                                            int partial, int failed, String message) {
        JsonObject root = new JsonObject();
        root.addProperty("schemaVersion", SCHEMA_VERSION);
        root.addProperty("engineVersion", ENGINE_VERSION);
        root.addProperty("recordType", "summary");
        root.addProperty("command", command);
        root.addProperty("total", total);
        root.addProperty("ok", ok);
        root.addProperty("partial", partial);
        root.addProperty("failed", failed);
        setResult(root, code, message);
        return root;
    }

    private static void setResult(JsonObject root, ResultCode code, String message) {
        JsonObject result = new JsonObject();
        result.addProperty("code", code.code);
        result.addProperty("name", code.name());
        result.addProperty("retryable", code.retryable);
        if (message == null || message.isEmpty()) addJsonNull(result, "message");
        else result.addProperty("message", message);
        root.add("result", result);
    }

    private static JsonObject errorObject(String field, ResultCode code, String message) {
        JsonObject item = new JsonObject();
        item.addProperty("field", field);
        item.addProperty("code", code.code);
        item.addProperty("name", code.name());
        item.addProperty("message", message);
        return item;
    }

    /** Structured daemon framing/protocol error; package-private for AppStateUtil. */
    static EngineResponse protocolError(ResultCode code, String message) {
        ResultCode safeCode = code == null ? ResultCode.INTERNAL_ERROR : code;
        return errorResponse(safeCode, "daemon", null, safe(message));
    }

    private static EngineResponse errorResponse(ResultCode code, String command, String packageName, String message) {
        JsonObject root = new JsonObject();
        root.addProperty("schemaVersion", SCHEMA_VERSION);
        root.addProperty("engineVersion", ENGINE_VERSION);
        root.addProperty("recordType", "error");
        root.addProperty("command", command == null ? "" : command);
        if (packageName == null) addJsonNull(root, "packageName");
        else root.addProperty("packageName", packageName);
        setResult(root, code, message);
        return new EngineResponse(code, GSON.toJson(root) + "\n");
    }

    private static EngineResponse batchSummaryOnly(String command, ResultCode code, int total, int ok,
                                                   int partial, int failed, String message) {
        return new EngineResponse(code,
                GSON.toJson(summaryRecord(command, code, total, ok, partial, failed, message)) + "\n");
    }

    private static ResultCode resultCodeFromRecord(JsonObject record) {
        try {
            String name = record.getAsJsonObject("result").get("name").getAsString();
            return ResultCode.valueOf(name);
        } catch (Throwable ignored) {
            return ResultCode.INTERNAL_ERROR;
        }
    }

    private static ResultCode mergeResult(ResultCode current, ResultCode next) {
        if (current == ResultCode.INTERNAL_ERROR || current == ResultCode.PERMISSION_DENIED
                || current == ResultCode.BAD_REQUEST || current == ResultCode.PACKAGE_NOT_FOUND) return current;
        if (next == ResultCode.INTERNAL_ERROR || next == ResultCode.PERMISSION_DENIED
                || next == ResultCode.BAD_REQUEST || next == ResultCode.PACKAGE_NOT_FOUND) return next;
        if (current == ResultCode.VERIFY_MISMATCH || next == ResultCode.VERIFY_MISMATCH) return ResultCode.VERIFY_MISMATCH;
        if (current == ResultCode.PARTIAL || next == ResultCode.PARTIAL || next == ResultCode.UNSUPPORTED) return ResultCode.PARTIAL;
        return ResultCode.OK;
    }

    private static ResultCode classifyThrowable(Throwable e) {
        if (e instanceof PackageManager.NameNotFoundException) return ResultCode.PACKAGE_NOT_FOUND;
        if (e instanceof SecurityException) return ResultCode.PERMISSION_DENIED;
        if (e instanceof UnsupportedOperationException) return ResultCode.UNSUPPORTED;
        if (e instanceof IllegalArgumentException) return ResultCode.BAD_REQUEST;
        return ResultCode.INTERNAL_ERROR;
    }

    private static List<String> dedupePackages(List<String> packageNames) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (packageNames != null) {
            for (String packageName : packageNames) {
                if (packageName == null) continue;
                String value = packageName.trim();
                if (value.isEmpty() || value.startsWith("#")) continue;
                out.add(value);
            }
        }
        return new ArrayList<>(out);
    }

    private static List<JsonObject> parseJsonRecords(String ndjson) {
        List<JsonObject> out = new ArrayList<>();
        if (ndjson == null) return out;
        int lineNo = 0;
        for (String line : ndjson.split("\\r?\\n")) {
            lineNo++;
            String value = line.trim();
            if (value.isEmpty() || value.startsWith("#")) continue;
            try {
                JsonElement element = JsonParser.parseString(value);
                if (!element.isJsonObject()) throw new IllegalArgumentException("line " + lineNo + " is not a JSON object");
                JsonObject object = element.getAsJsonObject();
                if ("summary".equals(stringMember(object, "recordType"))) continue;
                out.add(object);
            } catch (RuntimeException e) {
                throw new IllegalArgumentException("invalid NDJSON at line " + lineNo + ": " + failureMessage(e), e);
            }
        }
        return out;
    }

    private static JsonObject objectMember(JsonObject object, String name) {
        if (object == null || !object.has(name) || !object.get(name).isJsonObject()) return null;
        return object.getAsJsonObject(name);
    }

    private static String stringMember(JsonObject object, String name) {
        try {
            if (object == null || !object.has(name) || object.get(name).isJsonNull()) return "";
            return object.get(name).getAsString();
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static int intMember(JsonObject object, String name, int fallback) {
        try {
            if (object == null || !object.has(name) || object.get(name).isJsonNull()) return fallback;
            return object.get(name).getAsInt();
        } catch (Throwable ignored) {
            return fallback;
        }
    }


    private static String normalizeCommand(String command) {
        if (command == null) return "";
        String value = command.trim().toLowerCase(Locale.ROOT);
        switch (value) {
            case "snapshotappstatebatch": return "snapshot";
            case "restoreappstatebatch": return "restore";
            case "verifyappstatebatch": return "verify";
            default: return value;
        }
    }

    private static String failureMessage(Throwable e) {
        if (e == null) return "unknown";
        Throwable cause = e.getCause() != null ? e.getCause() : e;
        String message = cause.getMessage();
        if (message == null || message.trim().isEmpty()) message = cause.getClass().getSimpleName();
        return safe(message);
    }

    private static String safe(String value) {
        if (value == null) return "";
        return value.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').trim();
    }
}
