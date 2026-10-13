import Foundation

/// Decides from the Codex session itself whether a resume must go through
/// Subrouter, and repairs a launch record whose captured evidence disagrees.
///
/// A launch record proves a Subrouter route only through the agreeing marker
/// pair that `sr codex` and `cmux-codex-wrapper` export together. Records
/// captured from a launcher that did not export the marker, or recaptured from
/// an earlier plain `codex resume`, carry no proof even though the session was
/// created through Subrouter. Replaying them runs `codex resume <id>`, which
/// fails because the rollout's `subrouter` provider is not defined in the
/// user's own Codex config, or replays the dead per-launch relay URL that the
/// captured `-c model_providers.subrouter.*` options still name.
///
/// The rollout's `session_meta.model_provider` is the session's own record of
/// how it was created, so it decides when the record does not:
///
/// - `subrouter`: the record is rewritten to carry the marker pair for the
///   first Subrouter launcher on the restore `PATH`, so the existing routed
///   restore path resumes it through `<launcher> codex resume <id>`. When no
///   launcher resolves, the record is left as is and a notice names the fix.
/// - any other provider: Subrouter routing options and markers are removed
///   from a record that does not prove a Subrouter route, so a plain resume
///   cannot be pointed at a stale relay.
///
/// A record that already proves its route is kept unless its launcher is no
/// longer on the restore `PATH` and another supported one is.
struct CodexSessionRouteRepair {
    struct Result {
        var request: AgentRestoreRequest
        var notices: [AgentRestoreNotice]
    }

    private let router = SubrouterCodexResumeRouting()

    func repair(
        _ request: AgentRestoreRequest,
        kind: String,
        sessionModelProvider: () -> String?,
        isLauncherResolvable: (String) -> Bool
    ) -> Result {
        let unchanged = Result(request: request, notices: [])
        guard kind == "codex",
              request.mode == .resumeAgent,
              let sessionID = request.checkpointID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              var launch = request.launchCommand,
              !launch.arguments.isEmpty,
              launch.launcher == nil || launch.launcher?.lowercased() == "codex" else {
            return unchanged
        }

        let proven = router.resumeArguments(
            launcher: launch.launcher,
            sessionID: sessionID,
            launchArguments: launch.arguments,
            environment: launch.environment
        ) != nil
        // A proven route whose launcher still resolves is restored as recorded
        // without reading the rollout.
        if proven,
           let recorded = router.launchBoundLauncher(in: launch.environment),
           isLauncherResolvable(recorded) {
            return unchanged
        }
        guard let provider = sessionModelProvider() else { return unchanged }

        if provider == "subrouter" {
            guard let launcher = SubrouterCodexResumeRouting.supportedLaunchers.first(where: isLauncherResolvable),
                  let markers = router.markerEnvironment(launcher: launcher) else {
                return Result(
                    request: request,
                    notices: [.subrouterCodexLauncherUnavailable(sessionID: sessionID)]
                )
            }
            launch.environment = (launch.environment ?? [:]).merging(markers) { _, marker in marker }
            launch.arguments = router.argumentsProvingSubrouterProvider(launch.arguments)
            return Result(request: request.replacingLaunchCommand(launch), notices: [])
        }

        guard !proven else { return unchanged }
        let arguments = router.removingPrivateRoutingArguments(from: launch.arguments)
        var environment = launch.environment
        environment?.removeValue(forKey: SubrouterCodexResumeRouting.environmentKey)
        environment?.removeValue(forKey: SubrouterCodexResumeRouting.launchBoundEnvironmentKey)
        guard arguments != launch.arguments || environment != launch.environment else {
            return unchanged
        }
        launch.arguments = arguments
        launch.environment = environment
        var requestEnvironment = request.environment
        requestEnvironment.removeValue(forKey: SubrouterCodexResumeRouting.environmentKey)
        requestEnvironment.removeValue(forKey: SubrouterCodexResumeRouting.launchBoundEnvironmentKey)
        return Result(
            request: request.replacingLaunchCommand(launch, environment: requestEnvironment),
            notices: []
        )
    }
}

extension AgentRestoreRequest {
    func replacingLaunchCommand(
        _ launchCommand: AgentLaunchCommand,
        environment: [String: String]? = nil
    ) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: mode,
            kind: kind,
            checkpointID: checkpointID,
            source: source,
            workingDirectory: workingDirectory,
            environment: environment ?? self.environment,
            launchCommand: launchCommand,
            preparedArguments: preparedArguments,
            preparedArgumentsWorkingDirectory: preparedArgumentsWorkingDirectory,
            observedPermissionMode: observedPermissionMode
        )
    }
}
