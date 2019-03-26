using namespace System.Net
using namespace System.Web

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PoshChan-Bot received a request"
$request | out-string | write-host

$debugTrace = $false
$body = $Request.Body

function Write-Trace($message) {
    if ($debugTrace) {
        Write-Host $message
    }
}

function Push-GitHubComment($message, $url) {
    if ($null -eq $url) {
        $url = $body.issue.comments_url
    }

    Push-OutputBinding -Name githubrespond -Value @{ url = $url; message = $message }
}

function Send-Ok {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
    })
}

$githubEvent = $Request.Headers."X-GitHub-Event"
Write-Host "Received a '$githubEvent' event"

switch ($githubEvent) {

    "issue_comment" {
        $name = $Request.Query.Name
        if ($null -ne $name) {
            $poshchanMention = "@$name "
        }
        else {
            $poshchanMention = "@PoshChan "
        }

        if ($null -ne $Request.Query.DebugTrace) {
            $debugTrace = $true
        }

        $commentBody = $body.comment.body
        if (!($commentBody.StartsWith($poshchanMention, $true, $null))) {
            Write-Trace "Skipping message not sent to @PoshChan"
            Send-Ok
            return
        }

        # Don't act on edited comments
        if ($body.action -ne "created") {
            Write-Trace "Skipping message with action '$($body.action)'"
            Send-Ok
            return
        }

        $organization = $body.repository.owner.login
        $project = $body.repository.name
        if ($null -eq $organization -or $null -eq $project) {
            Write-Error "Organization or Project was null"
            Send-Ok
            return
        }

        $settings = Get-Settings -organization $organization -project $project

        $user = $body.comment.user.login
        $pr = $body.issue.pull_request.url
        if ($null -eq $pr) {
            Write-Warning "Ignoring non-PR comment"
            Send-Ok
            return
        }

        $command = $commentBody.SubString($poshchanMention.Length)

        if (-not $command.StartsWith("Please ", $true, $null)) {
            $message = "@$user, all requests start with the magic word ``Please``."
            Push-GitHubComment -message $message
            Send-Ok
            return
        }

        switch -regex ($command.TrimEnd()) {
            "Please (?<action>rebuild|rerun|retry) (?<target>.+)" {

                if ($null -eq $settings.azdevops -or $null -eq $settings.azdevops.authorized_users) {
                    $message = "@$user, rebuilds are not enabled for this repo."
                    Push-GitHubComment -message $message
                }

                $authorized_users = $settings.azdevops.authorized_users
                if ($authorized_users -ne "*" -and $user -notin $authorized_users) {
                    $message = "@$user, you are not authorized to request a rebuild"
                    Push-GitHubComment -message $message
                    break
                }
                elseif ($null -eq $authorized_users) {
                    $message = "@$user, authorized users for ``Build Targets`` hasn't been set, so this action is not allowed."
                    Push-GitHubComment -message $message
                    break
                }

                $action = $matches.action.ToLower()
                # rerun == rebuild
                if ($action -eq "rerun") {
                    $action = "rebuild"
                }

                $targets = $matches.target.Split(",").Trim()
                $build_targets = @($settings.azdevops.build_targets.psobject.properties.name)
                Write-Host "Found build_targets: $([string]::Join(',',$build_targets))"
                $invalid = $targets | Where-Object { $build_targets -notcontains $_ }
                if ($invalid) {
                    $supported = [string]::Join(", ", ($build_targets | ForEach-Object { "``$_``" }))
                    $message = "@$user, I do not understand the build target(s) ``$([string]::Join(", ",$invalid))``; I only allow $supported"
                    Push-GitHubComment -message $message
                    break
                }

                $resolvedTargets = [System.Collections.ArrayList]::new()
                foreach ($target in $targets) {
                    $context = $settings.azdevops.build_targets.$target
                    if ($context.Count -gt 1) {
                        foreach ($subTarget in $context) {
                            $resolvedTargets += $subTarget
                        }
                    }
                    else {
                        $resolvedTargets += $context
                    }
                }

                $context = $resolvedTargets | Select-Object -Unique
                if ($null -eq $context) {
                    $message = "@$user, could not find a matching build target"
                    Push-GitHubComment -message $message
                    break
                }

                $queueItem = @{
                    context = $context
                    action = $action
                    pr = $pr
                    commentsUrl = $body.issue.comments_url
                    user = $user
                    organization = $organization
                    project = $project
                }

                Write-Host "Queuing rebuild for '$([string]::Join(", ",$context))'"
                Push-Queue -Queue azdevops-rebuild -Object $queueItem
                break
            }

            "Please remind me in (?<time>\d+) (?<units>.+)" {

                if ($null -eq $settings.reminders -or $null -eq $settings.reminders.authorized_users) {
                    $message = "@$user, reminders are not enabled for this repo."
                    Push-GitHubComment -message $message
                }

                $authorized_users = $settings.reminders.authorized_users
                if ($authorized_users -ne "*" -and $user -notin $authorized_users) {
                    $message = "@$user, you are not authorized to request a reminder"
                    Push-GitHubComment -message $message
                    break
                }
                elseif ($null -eq $authorized_users) {
                    $message = "@$user, authorized users for ``Reminders`` hasn't been set, so this action is not allowed."
                    Push-GitHubComment -message $message
                    break
                }

                [int]$time = $matches.time
                $units = $matches.units

                switch -regex ($units.ToLower()) {
                    "minute(s?)" {
                        $timeSeconds = $time * 60
                        break
                    }

                    "hour(s?)" {
                        $timeSeconds = $time * 60 * 60
                        break
                    }

                    "day(s?)" {
                        $timeSeconds = $time * 60 * 60 * 24
                        break
                    }

                    default {
                        $message = "@$user, I do not understand '$units'; I only allow ``minutes``,``hours``, and ``days``"
                        Push-GitHubComment -message $message
                        break
                    }
                }

                $message = "@$user, will remind you in $time $units"
                Push-GitHubComment -message $message

                $message = "@$user, this is the reminder you requested $time $units ago"
                Push-Queue -Queue github-respond -Object @{ url = $body.issue.comments_url; message = $message } -VisibilitySeconds $timeSeconds
                break
            }

            default {
                $message = "@$user, I do not understand: $command"
                Push-GitHubComment -message $message
                break
            }
        }
    }

    "status" {
        if ($Request.Body.state -eq "failure") {
            $githubOrganization, $githubProject = $Request.Body.Name.Split("/")

            if ($Request.Body.Description -match "^#PR-(?<prId>[0-9]+)-.*?") {
                $prId = $matches.prId
            }
            else {
                Write-Error "Could not extract PR id from '$($Request.Body.Description)'"
                break
            }

            $committer = $request.body.commit.committer.login
            if ($committer -ne "SteveL-MSFT") {
                Write-Error "Committer is not SteveL-MSFT"
                break
            }

            if ($Request.Body.target_url -match "^.*?\?buildId=(?<buildId>[0-9]+)") {
                $buildId = $matches.buildId
            }
            else {
                Write-Error "Could not extract buildId from '$($Request.Body.target_url)'"
                break
            }

            $devOpsOrganization, $devOpsProject = Get-DevOpsOrgAndProject -Settings $settings -DefaultOrganization $githubOrganization -DefaultProject $githubProject
            $build = Get-DevOpsBuild -Organization $devOpsOrganization -Project $devOpsProject -BuildId $buildId
            $failures = Get-DevOpsTestFailures -Organization $settings.azdevops.organization -Project $settings.azdevops.project -BuildUri $build.uri
            $sb = [System.Text.StringBuilder]::new()
            $null = $sb.Append("@$committer, your last commit had $($failures.Count) failures in $($Request.Body.Context):`n")
            $count = $failures.Count
            if ($count -gt 10) {
                $null = $sb.Append("(These are 10 of the failures)")
                $count = 10
            }

            for ($i = 0; $i -lt $count; $i++) {
                $null = $sb.Append("### $($failures[$i].testcaseTitle)`n")
                $null = $sb.Append("  Error: $($failures[$i].errorMessage)`n")
                $null = $sb.Append("``````stacktrace`n")
                $null = $sb.Append($failures[$i].stacktrace)
                $null = $sb.Append("`n```````n")
            }

            $message = $sb.ToString()
            $githubPr = Get-GitHubPullRequest -PullRequestUrl "https://api.github.com/repos/$githubOrganziation/$githubProject/issues/$prId"
            Push-GitHubComment -message $message -url $githubPr.comments_url
            break
        }
    }

    default {
        Write-Error "Unknown event type: $githubEvent"
    }
}

Send-Ok
