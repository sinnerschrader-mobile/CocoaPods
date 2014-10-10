require 'resolver'
require 'cocoapods/resolver/lazy_specification'

module Pod
  # The resolver is responsible of generating a list of specifications grouped
  # by target for a given Podfile.
  #
  class Resolver
    include ::Resolver::UI
    include ::Resolver::SpecificationProvider

    # @return [Sandbox] the Sandbox used by the resolver to find external
    #         dependencies.
    #
    attr_reader :sandbox

    # @return [Podfile] the Podfile used by the resolver.
    #
    attr_reader :podfile

    # @return [Array<Dependency>] the list of dependencies locked to a specific
    #         version.
    #
    attr_reader :locked_dependencies

    # @return [Array<Source>] The list of the sources which will be used for
    #         the resolution.
    #
    attr_accessor :sources

    # @param  [Sandbox] sandbox @see sandbox
    # @param  [Podfile] podfile @see podfile
    # @param  [Array<Dependency>] locked_dependencies @see locked_dependencies
    # @param  [Array<Source>, Source] sources @see sources
    #
    def initialize(sandbox, podfile, locked_dependencies, sources)
      @sandbox = sandbox
      @podfile = podfile
      @locked_dependencies = locked_dependencies
      @sources = Array(sources)
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Resolution

    # Identifies the specifications that should be installed.
    #
    # @return [Hash{TargetDefinition => Array<Specification>}] specs_by_target
    #         the specifications that need to be installed grouped by target
    #         definition.
    #
    def resolve
      @cached_sets = {}
      @activated = ::Resolver::Resolver.new(self, self).
        resolve(
          @podfile.target_definition_list.map(&:dependencies).flatten,
          locked_dependencies.reduce(::Resolver::DependencyGraph.new) do |graph, locked|
            graph.tap { |g| g.add_root_vertex(locked.name, locked) }
          end
        )
      specs_by_target
    rescue ::Resolver::ResolverError => e
      raise Informative, e.message
    end

    def search_for(dependency)
      @search ||= {}
      @search[dependency] ||= begin
        find_cached_set(dependency).
          all_specifications.
          select { |s| dependency.requirement.satisfied_by? Version.new(s.version) }.
          reject { |s| !dependency.prerelease? && s.version.prerelease? }.
          reverse.
          map { |s| s.subspec_by_name dependency.name rescue nil }.
          compact.
          each { |s| s.version.head = dependency.head? }
      end
      @search[dependency].dup
    end

    def dependencies_for(dependency)
      dependency.all_dependencies
    end

    def name_for(dependency)
      dependency.name
    end

    def requirement_satisfied_by?(requirement, activated, spec)
      existing = activated.vertices.values.map(&:payload).compact.find { |s| Specification.root_name(s.name) ==  Specification.root_name(requirement.name) }
      if existing
        existing.version == spec.version &&
          requirement.requirement.satisfied_by?(spec.version)
      else
        requirement.requirement.satisfied_by? spec.version
      end
    end

    # Sort dependencies so that the ones that are easiest to resolve are first.
    # Easiest to resolve is (usually) defined by:
    #   1) Is this dependency already activated?
    #   2) How relaxed are the requirements?
    #   3) Are there any conflicts for this dependency?
    #   4) How many possibilities are there to satisfy this dependency?
    #
    def sort_dependencies(dependencies, activated, conflicts)
      dependencies.sort_by do |dependency|
        name = name_for(dependency)
        [
          activated.vertex_named(name).payload ? 0 : 1,
          conflicts[name] ? 0 : 1,
          search_for(dependency).count,
        ]
      end
    end

    # @return [Hash{Podfile::TargetDefinition => Array<Specification>}]
    #         returns the resolved specifications grouped by target.
    #
    # @note   The returned specifications can be subspecs.
    #
    def specs_by_target
      @specs_by_target ||= begin
        specs_by_target = {}
        podfile.target_definition_list.each do |target|
          specs_by_target[target] = target.dependencies.map(&:name).map do |name|
            node = @activated.vertex_named(name)
            (node.recursive_successors << node).to_a
          end.
            flatten.
            map(&:payload).
            uniq.
            sort { |x, y| x.name <=> y.name }.
            each do |spec|
              validate_platform(spec, target)
              sandbox.store_head_pod(spec.name) if spec.version.head
            end
        end
        specs_by_target
      end
    end

    #-------------------------------------------------------------------------#

    private

    # !@ Resolution context

    # @return [Hash<String => Set>] A cache that keeps tracks of the sets
    #         loaded by the resolution process.
    #
    # @note   Sets store the resolved dependencies and return the highest
    #         available specification found in the sources. This is done
    #         globally and not per target definition because there can be just
    #         one Pod installation, so different version of the same Pods for
    #         target definitions are not allowed.
    #
    attr_accessor :cached_sets

    #-------------------------------------------------------------------------#

    private

    # @!group Private helpers

    # @return [Set] Loads or returns a previously initialized set for the Pod
    #               of the given dependency.
    #
    # @param  [Dependency] dependency
    #         The dependency for which the set is needed.
    #
    # @return [Set] the cached set for a given dependency.
    #
    def find_cached_set(dependency)
      name = dependency.root_name
      unless cached_sets[name]
        if dependency.external_source
          spec = sandbox.specification(name)
          unless spec
            raise StandardError, '[Bug] Unable to find the specification ' \
              "for `#{dependency}`."
          end
          set = Specification::Set::External.new(spec)
        else
          set = create_set_from_sources(dependency)
        end
        cached_sets[name] = set
        unless set
          raise Informative, 'Unable to find a specification for ' \
            "`#{dependency}`."
        end
      end
      cached_sets[name]
    end

    # @return [Set] Creates a set for the Pod of the given dependency from the
    #         sources. The set will contain all versions from all sources that
    #         include the Pod.
    #
    # @param  [Dependency] dependency
    #         The dependency for which the set is needed.
    #
    def create_set_from_sources(dependency)
      aggregate.search(dependency)
    end

    # @return [Source::Aggregate] The aggregate of the {#sources}.
    #
    def aggregate
      @aggregate ||= Source::Aggregate.new(sources.map(&:repo))
    end

    # Ensures that a specification is compatible with the platform of a target.
    #
    # @raise  If the specification is not supported by the target.
    #
    # @todo   This step is not specific to the resolution process and should be
    #         performed later in the analysis.
    #
    # @return [void]
    #
    def validate_platform(spec, target)
      unless spec.available_platforms.any? { |p| target.platform.supports?(p) }
        raise Informative, "The platform of the target `#{target.name}` "     \
          "(#{target.platform}) is not compatible with `#{spec}` which has "  \
          "a minimum requirement of #{spec.available_platforms.join(' - ')}."
      end
    end
  end
end
