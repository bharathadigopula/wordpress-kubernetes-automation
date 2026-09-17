//==============================================================================
// WORDPRESS KUBERNETES REPOSITORY VALIDATION
//==============================================================================

@Library('jenkins-pipeline-templates@v1.4.10') _

repositoryValidationPipeline(
    githubRepository: 'bharathadigopula/wordpress-kubernetes-automation',
    shellSearchPath: 'scripts',
    validationScript: 'scripts/validate.sh',
    timeoutMinutes: 20
)