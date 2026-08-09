import ProjectDescription

let tuist = Tuist(
    fullHandle: "alexey1312/reachy-mini-swift",
    project: .tuist(
        // A set `fullHandle` otherwise makes generation require a tuist.dev session, which
        // CI and forks have none of. The project itself is connected; what is optional here
        // is the session, not the connection.
        // Caching needs the local cache service from `tuist setup cache` (a LaunchAgent);
        // bootstrap.sh runs it. Without the daemon every compile task waits out a CAS
        // socket deadline, so CI enables it only after its own setup step succeeds.
        generationOptions: .options(
            optionalAuthentication: true,
            enableCaching: Environment.cacheEnabled.getBoolean(default: true)
        )
    )
)
