require "grit"
require "json"

# You can override these defaults in your Jekyll _config.yml file.
#
# E.g., to use "article.{extension}" as the main file to be rendered,
# and to tell Gekyll not to write out the full, raw repo, you'd add
# these lines to your _config.yml:
#
# gekyll:
# 	filename_matches:
# 		- article
# 	extras:
# 		- blobs
# 		- commits
# 		- diffs
# 		
GEKYLL_DEFAULTS = {
	"filename_matches" => [ "draft", "readme" ],
	"extension_matches" => [ "md", "mkd", "markdown", "txt" ],
	"extras" => [ "repo", "blobs", "commits", "diffs" ]
}

module Grit
	class Git
		# Overrides GitRuby.diff, which seems to be
		# ignoring `options`.
		def diff(options, sha1, sha2 = nil)
			self.native("diff", options, sha1, sha2)
		end
	end
	class Commit
		# Make commits play nice with Liquid templates.
		def to_liquid
			self.to_hash
		end
	end
	class Tree
		# Adding a recursion method to Grit::Tree. This method traverses
		# a tree structure (directory) and calls a `callback` Proc 
		# on every blob encountered.
		#
		# The callback should accept two parameters, `blob` and `tree`.
		def recurse(callback)
			self.blobs.each do |blob|
				callback.call(blob, self)
			end
			self.trees.each { |subtree| self.recurse(subtree, callback) }
		end
	end
end

module Jekyll
	class Post
		# If you want Gekyll to recognize your repo, it should exist as
		# a "bare" (though not empty) Git repository in the _posts
		# directory and its name should end in ".git"
		def self.repo?(name)
			name[-4..-1] == ".git"
		end

		# Override Jekyll::Post.valid?
		def self.valid?(name)
			self.repo?(name) or name =~ MATCHER
		end

		# Override Jekyll::Post.new
		# Intercept repos, and make them instances of GekyllPost instead of Post
		class << self
			alias_method :new_orig, :new
			def new(*args)
				site, source, dir, name = *args
				if self.repo?(name) and self != GekyllPost
					return GekyllPost.new(*args)
				end
				puts ">> #{name} [#{self.name.split("::").last}]"
				new_orig(*args)
			end
		end
	end
	class GekyllPost < Post
		# Make .repo and .commits publicly accessible, so they can be used in layouts
		attr_accessor :repo, :commits

		# Override Jekyll::Post.process
		GITMATCHER = /^(.+\/)*(.*)(\.git)$/
		def process(name)
			m, cats, slug, ext = *name.match(GITMATCHER)
			@gekyll_config = GEKYLL_DEFAULTS.merge(@site.config['gekyll'] || {})
			self.slug = slug
			self.repo = Grit::Repo.new File.join(@base, name)
			self.commits = self.repo.commits("master", 10e10)
		end

		# Override Jekyll::Post.read_yaml
		def read_yaml(base, name)
			raise "Repo named #{name} has no commits." if not self.commits.first

			# Get all the files in the repo's ground-floor directory
			blobs = self.commits.first.tree.blobs

			# Look for the matching filenames, and sort them according 
			# to their index in "filename_matches".
			matching = blobs.each_with_index.map do |b,i| 
				index = @gekyll_config["filename_matches"].index b.name.split(".")[0].downcase
				index ? [ b, i ] : nil
			end.compact.sort { |a,b| a[1] <=> b[1] }.map(&:first)

			# Failing that, look for the matching file extensions.
			if matching.empty?
				matching = blobs.each_with_index.map do |b,i| 
					index = @gekyll_config["extension_matches"].index b.name.split(".")[-1].downcase
					index ? [ b, i ] : nil
				end.compact.sort { |a,b| a[1] <=> b[1] }.map(&:first)
			end
			raise "Repo named #{name} has no files matching {#{@gekyll_config["filename_matches"].join(",")}}.{#{@gekyll_config["extension_matches"]}}" if matching.empty?

			# Consider the first matching file to be our main content.
			matched = matching.first
			self.content = matched.data
			self.ext = matched.name.split(".")[-1]

			# This chunk comes from standard Jekyll
			begin
				if self.content =~ /^(---\s*\n.*?\n?)^(---\s*$\n?)/m
					self.content = $POSTMATCH
					self.data = YAML.load($1)
				end
			rescue => e
				puts "YAML Exception reading #{name}: #{e.message}"
			end

			# Add "is_repo" variable to YAML-read data,
			# and set relevant data fields
			self.data ||= {}
			self.data["is_repo"] = true
			self.data["commits"] = self.commits
			self.data["date"] ||= self.commits.first.committed_date
			self.data["start_date"] ||= self.commits.last.committed_date
			self.data["layout"] ||= "repo"
		end

		# Aliased `write` to also write repo-related files.
		alias_method :write_orig, :write
		def write(dest)
			write_orig(dest)
			write_extras(dest)
		end

		def write_extras(dest)
			path = File.join(dest, CGI.unescape(self.url))
			commits = self.commits

			# Write bare git repo to post's main directory
			write_raw_repo = lambda do
				forked = self.repo.fork_bare(path[0..-2] + ".git")

				# Make sure that repo can be cloned from a static server
				forked.git.native(:repack)
				forked.git.native(:update_server_info)
			end

			# Write raw blobs/files to post's raw/ subdirectory
			write_raw_blobs = lambda do
				raw_path = File.join(path, "raw")

				commits.first.tree.recurse(Proc.new { |blob, tree| 
					filepath = File.join([raw_path, tree.name, blob.name].compact)
					FileUtils.mkdir_p(File.dirname(filepath))
					File.open(filepath, 'w') do |f|
						f.write(blob.data)
					end
				})
			end

			# Write commits.json
			write_commits = lambda do
				def commits_json (commits)
					commits.map do |c|
						c.to_hash.deep_merge({ files: c.stats.files })
					end.to_json
				end
				File.open(File.join(path, "commits.json"), "w") do |f|
					f.write(commits_json(commits))
				end
			end

			# Write diffs as series of JSON files
			write_diffs = lambda do
				diffs_path = File.join(path, "diffs")
				FileUtils.mkdir_p(diffs_path)
				commits.each do |c|
					diffs = c.diffs({ :word_diff => "plain", :unified => 1, :ignore_all_space => true })
					diff_hashes = diffs.map do |d| 
						hide_diff = (d.new_file or d.deleted_file or d.renamed_file)
						{
							"a_path" => d.a_path,
							"b_path" => d.b_path,
							"new_file" => d.new_file,
							"deleted_file" => d.deleted_file,
							"renamed_file" => d.renamed_file,
							"similarity_index" => d.similarity_index,
							"diff" => hide_diff ? nil : d.diff.force_encoding("UTF-8")
						}
					end
					File.open(File.join(diffs_path, "#{c.id}.json"), "w") do |f|
						f.write JSON.dump(diff_hashes) 
					end
				end
			end

			extras = @gekyll_config["extras"]
			write_raw_repo.call if extras.include? "repo"
			write_raw_blobs.call if extras.include? "blobs"
			write_commits.call if extras.include? "commits"
			write_diffs.call if extras.include? "diffs"
		end
	end
end
