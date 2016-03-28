class BuildMailer < ActionMailer::Base
  helper :application, :mail

  default :from => Proc.new { Settings.sender_email_address }

  private

  def pull_request_link(build)
    @build = build

    remote_server = @build.repository.remote_server
    if remote_server.class == RemoteServer::Stash && !@build.branch_record.convergence?
      begin
        id, _ = remote_server.get_pr_id_and_version(@build.branch_record.name)
        return "#{remote_server.base_html_url}/pull-requests/#{id}/overview"
      rescue RemoteServer::StashAPIError
        # not all branches will have an open pull request
        return nil
      end
    end
    nil
  end

  public

  def error_email(build_attempt, error_text = nil)
    @build_part = build_attempt.build_part
    @builder = build_attempt.builder
    @error_text = error_text
    mail :to => Settings.kochiku_notifications_email_address,
         :subject => "[kochiku] Build part errored on #{@builder}",
         :from => Settings.sender_email_address
  end

  def build_break_email(build)
    @build = build

    # Allow the partitioner to be selective about who is emailed
    partitioner = Partitioner.for_build(@build)
    @responsible_email_and_files = partitioner.emails_for_commits_causing_failures
    @emails = @responsible_email_and_files.keys
    if @emails.empty?
      @emails = if @build.branch_record.convergence?
                  GitBlame.emails_since_last_green(@build)
                else
                  GitBlame.emails_in_branch(@build)
                end
    end

    @git_changes = if @build.branch_record.convergence?
                     GitBlame.changes_since_last_green(@build)
                   else
                     GitBlame.changes_in_branch(@build)
                   end

    @failed_build_parts = @build.build_parts.failed_or_errored.decorate
    @pr_link = pull_request_link(build)

    mail :to => @emails,
         :bcc => Settings.kochiku_notifications_email_address,
         :subject => "[kochiku] Failure - #{@build.branch_record.name} build for #{@build.repository.name}",
         :from => Settings.sender_email_address
  end

  def build_success_email(build)
    @build = build
    @email = GitBlame.last_email_in_branch(@build)
    @git_changes = GitBlame.changes_in_branch(@build)
    @pr_link = pull_request_link(build)

    mail :to => @email,
         :bcc => Settings.kochiku_notifications_email_address,
         :subject => "[kochiku] Success - #{@build.branch_record.name} build for #{@build.repository.name}",
         :from => Settings.sender_email_address
  end
end
