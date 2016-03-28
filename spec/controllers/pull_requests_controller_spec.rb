require 'spec_helper'

describe PullRequestsController do
  before do
    settings = SettingsAccessor.new(<<-YAML)
    git_servers:
      github.com:
        type: github
      git.example.com:
        type: github
    YAML
    stub_const "Settings", settings
  end

  describe "#build" do

    describe "post /pull-request-builder" do
      context "from github" do
        let(:repository_fields) { Hash.new }  # expected to be overwritten by a sub-context
        let!(:repository) do
          FactoryGirl.create(:repository,
                             { url: "git@git.example.com:square/web.git" }.merge(repository_fields)
                            )
        end

        context "for push events" do
          let(:repository_fields) { { run_ci: true } }
          let!(:master_branch) { FactoryGirl.create(:master_branch, repository: repository) }
          let!(:convergence_branch) { FactoryGirl.create(:branch, repository: repository, convergence: true, name: "convergence_branch") }

          it "creates a build" do
            expect(Build.where(branch_id: master_branch.id, ref: to_40('2'))).to_not exist
            expect {
              post :build, 'payload' => push_payload
              expect(response).to be_success
            }.to change(Build, :count).by(1)
            expect(Build.where(branch_id: master_branch.id, ref: to_40('2'))).to exist
          end

          it "does not create a build for pushes to non-convergence branches" do
            expect {
              post :build, 'payload' => push_payload("ref" => "refs/heads/some-branch")
              expect(response).to be_success
            }.to_not change(Build, :count)
          end

          it "does not a build if repository disabled ci" do
            repository.update_attributes!(:run_ci => false)
            expect {
              post :build, 'payload' => push_payload
              expect(response).to be_success
            }.to_not change(Build, :count)
          end

          it "does not build if there is an active ci build" do
            master_branch.builds.create!(:ref => to_40('w'), :state => :succeeded)
            frozen_time = 3.seconds.from_now
            allow(Time).to receive(:now).and_return(frozen_time)
            master_branch.builds.create!(:ref => to_40('y'), :state => :partitioning)
            expect {
              post :build, 'payload' => push_payload
              expect(response).to be_success
            }.to_not change(Build, :count)
          end

          it "builds for convergence branches" do
            expect {
              post :build, 'payload' => push_payload("ref" => "refs/heads/convergence_branch")
              expect(response).to be_success
            }.to change(Build, :count).by(1)
          end

          it "builds if there is completed ci build" do
            master_branch.builds.create!(:ref => to_40('w'), :state => :succeeded)
            expect {
              post :build, 'payload' => push_payload
              expect(response).to be_success
            }.to change(Build, :count).by(1)
          end

          it "builds if there is a completed ci build after a build that is still building" do
            master_branch.builds.create!(:ref => to_40('w'), :state => :partitioning)
            frozen_time = 3.seconds.from_now
            allow(Time).to receive(:now).and_return(frozen_time)
            master_branch.builds.create!(:ref => to_40('y'), :state => :succeeded)
            expect {
              post :build, 'payload' => push_payload
              expect(response).to be_success
            }.to change(Build, :count).by(1)
          end

          it "it should not error if the repository url in the request is not found" do
            expect {
              post :build, 'payload' => push_payload("repository" => {"url" => "git@git.example.com:doesnot/exist.git"})
              expect(response).to be_success
            }.to_not change(Build, :count)
          end
        end

        context "for pull requests" do
          let(:repository_fields) { { run_ci: true, build_pull_requests: true } }

          context "when there is no existing Branch record" do
            it "should create a Branch record on demand" do
              expect(Branch.where(repository: repository, name: "branch-name")).to_not exist
              post :build, 'payload' => pull_request_payload
              expect(response).to be_success
              expect(Branch.where(repository: repository, name: "branch-name")).to exist
            end
          end

          context "when the pull request sha has already been built" do
            before do
              @github_payload = pull_request_payload(
                "pull_request" => {
                  "head" => {"sha" => "de8251ff97ee194a289832576287d6f8ad74e3d0", "ref" => "branch-name"},
                  "body" => "best pull request ever",
                })
            end
            let!(:branch) { FactoryGirl.create(:branch, repository: repository, name: "branch-name") }

            it "has no effect" do
              FactoryGirl.create(:build, :branch_id => branch.id, :ref => "de8251ff97ee194a289832576287d6f8ad74e3d0")

              expect {
                post :build, 'payload' => @github_payload
                expect(response).to be_success
              }.to_not change(Build, :count)
            end

            it "still creates a build if the sha is used by a different repo" do
              common_sha = "de8251ff97ee194a289832576287d6f8ad74e3d0"
              # create build with the same ref on a different repository
              FactoryGirl.create(:build, ref: common_sha)

              expect(Build.where(branch_id: branch.id, ref: common_sha)).to_not exist
              post :build, 'payload' => @github_payload
              expect(Build.where(branch_id: branch.id, ref: common_sha)).to exist
            end
          end

          context do
            let(:branch) { FactoryGirl.create(:branch, repository: repository, name: "branch-name") }

            it "creates a build for a pull request" do
              expect(Build.where(branch_id: branch.id, ref: to_40('1'))).to_not exist
              expect {
                post :build, 'payload' => pull_request_payload
                expect(response).to be_success
              }.to change(Build, :count).by(1)
              expect(Build.where(branch_id: branch.id, ref: to_40('1'))).to exist
            end

            it "does not create a build if build_pull_requests is disabled" do
              repository.update_attribute(:build_pull_requests, false)
              expect {
                post :build, 'payload' => pull_request_payload({"pull_request" => {"body" => "don't build it"}})
                expect(response).to be_success
              }.to_not change(branch.builds, :count)
            end

            it "does not build a closed pull request" do
              expect {
                post :build, 'payload' => pull_request_payload({"action" => "closed"})
                expect(response).to be_success
              }.to_not change(branch.builds, :count)
            end

            it "does not blow up if action is missing" do
              post :build, 'payload' => pull_request_payload({"action" => nil})
              expect(response).to be_success
            end

            context "when there are other builds for the same branch" do
              let!(:build_one) { FactoryGirl.create(:build, :branch_record => branch, :ref => to_40('w')) }
              let!(:build_two) { FactoryGirl.create(:build, :branch_record => branch, :ref => to_40('y')) }

              it "aborts previous builds of the same branch" do
                github_payload = pull_request_payload(
                  "pull_request" => {
                    "head" => {"sha" => to_40('z'), "ref" => branch.name},
                    "body" => "best pull request ever",
                  })

                expect {
                  post :build, 'payload' => github_payload
                  expect(response).to be_success
                }.to change(Build, :count)
                expect(build_one.reload).to be_aborted
                expect(build_two.reload).to be_aborted
              end
            end
          end
        end

        it "does not blow up if pull_request data is missing" do
          expect {
            post :build, 'payload' => pull_request_payload({"pull_request" => nil})
            expect(response).to be_success
          }.to_not change(Build, :count)
        end

        it "should not error if the repository url in the request is not found" do
          expect {
            pr_payload = pull_request_payload("repository" => { "ssh_url" => "git@git.example.com:doesnot/exist.git" })
            post :build, 'payload' => pr_payload
            expect(response).to be_success
          }.to_not change(Build, :count)
        end
      end
    end
  end

  def pull_request_payload(options = {})
    {
      "pull_request" => {
        "head" => {
          "sha" => to_40('1'),
          "ref" => "branch-name"
        },
        "body" => "best pull request ever",
        "title" => "this is a pull request",
      },
      "repository" => {
        "ssh_url" => "git@git.example.com:square/web.git",
      },
      "action" => "synchronize",
    }.deep_merge(options).to_json
  end

  def push_payload(options = {})
    {
      "after" => to_40('2'),
      "repository" => {
        "url" => "https://git.example.com/square/web",
      },
      "ref" => "refs/heads/master",
    }.deep_merge(options).to_json
  end
end
