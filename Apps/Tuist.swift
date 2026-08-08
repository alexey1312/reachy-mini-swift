import ProjectDescription

let tuist = Tuist(
    fullHandle: "alexey1312/reachy-mini-swift",
    project: .tuist(
        // A set `fullHandle` otherwise makes generation require a tuist.dev session, which
        // CI and forks have none of. The project itself is connected; what is optional here
        // is the session, not the connection.
        generationOptions: .options(optionalAuthentication: true)
    )
)
