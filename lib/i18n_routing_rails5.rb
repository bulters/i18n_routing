# encoding: utf-8
require 'action_dispatch/journey/router'
require 'action_dispatch'
require 'active_support/core_ext/module'


module I18nRouting
  module Mapper

    private

    # Just create a Mapper:Resource with given parameters
    def resource_from_params(type, *resources)
      res = resources.clone

      options = res.extract_options!
      r = res.first

      type == :resource ? ActionDispatch::Routing::Mapper::SingletonResource.new(r, api_only?, @scope[:shallow], options.dup) : ActionDispatch::Routing::Mapper::Resource.new(r, api_only?, @scope[:shallow], options.dup)
    end

    # Localize a resources or a resource
    def localized_resources(type = :resources, *resources, &block)
      localizable_route = nil

      if @locales
        res = resources.clone

        options = res.extract_options!
        r = res.first

        resource = resource_from_params(type, r, options.dup)

        # Check for translated resource
        stored_locale = I18n.locale

        @locales.each do |locale|
          I18n.locale = locale
          localized_path = I18nRouting.translation_for(resource.name, type)

          # A translated route exists :
          if !localized_path.blank? and String === localized_path
            puts("[I18n] > localize %-10s: %40s (%s) => /%s" % [type, resource.name, locale, localized_path]) if @i18n_verbose
            opts = options.dup
            opts[:path] = (Admin::AppConfig.get('base.available_locales').count > 1 and not @omit_locale) ? "#{locale}/#{localized_path}" : localized_path
            opts[:controller] ||= r.to_s.pluralize
            opts[:locale] = locale.to_sym

            resource = resource_from_params(type, r, opts.dup)

            res = ["#{I18nRouting.locale_escaped(locale)}_#{r}".to_sym, opts]

            constraints = opts[:constraints] ? opts[:constraints].dup : {}

            scope(constraints: constraints, :path_names => I18nRouting.path_names(resource.name, @scope)) do
              localized_branch(locale) do
                send(type, *res) do

                  # In the resource(s) block, we need to keep and restore some context :
                  if block
                    old_name = @scope[:i18n_real_resource_name]
                    old = @scope[:scope_level_resource]

                    @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(i18n_real_resource_name: resource.name))  # total hack :)
                    @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(i18n_scope_level_resource: old))  # total hack :)
                    @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(scope_level_resource: resource))  # total hack :)

                    if type == :resource and @scope[:name_prefix]
                      # Need to fake name_prefix for singleton resource
                      @scope[:name_prefix] = @scope[:name_prefix].gsub(Regexp.new("#{old.name}$"), resource.name)
                    end

                    block.call if block

                    @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(scope_level_resource: old))
                    @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(i18n_real_resource_name: old_name))
                  end

                  @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(i18n_scope_level_resource: nil))
                end
              end
            end

            localizable_route = resource
          end
        end
        I18n.locale = stored_locale
      end
      return localizable_route
    end

    # Set if the next route created will be a localized route or not
    # If yes, localizable is a name, or a Mapper::Resource
    # Can take a block, if so, save the current context, set the new
    # Call the block, then restore the old context and return the block return
    def set_localizable_route(localizable)
      if block_given?
        old = @set.named_routes.localizable
        @set.named_routes.set_localizable_route(localizable)
        r = yield
        @set.named_routes.set_localizable_route(old)
        return r
      else
        @set.named_routes.set_localizable_route(localizable)
      end
    end

    def localizable_route
      @set.named_routes.localizable
    end

    # Return the aproximate deep in scope level
    def nested_deep
      (@scope and Array === @scope[:nested_deep] and @scope[:scope_level]) ? @scope[:nested_deep].size : 0
    end

    public



    # Rails 3 routing system
    # Create a block for localized routes, in your routes.rb :
    #
    # localized do
    #   resources :users
    #   match 'about' => 'contents#about', :as => :about
    # end
    #
    def localized(locales = I18n.available_locales, opts = {})
      # Add if not added Rails.root/config/locales/*.yml in the I18n.load_path
      if !@i18n_routing_path_set and defined?(Rails) and Rails.respond_to?(:root) and Rails.root
        I18n.load_path = (I18n.load_path << Dir[Rails.root.join('config', 'locales', '*.yml')]).flatten.uniq
        @i18n_routing_path_set = true
      end

      old_value = @locales
      @locales = locales
      @omit_locale = opts.delete(:omit_locale)
      @i18n_verbose ||= opts.delete(:verbose)
      yield
    ensure
      @locales = old_value
    end

    # Create a branch for create routes in the specified locale
    def localized_branch(locale)
      set_localizable_route(nil) do
        old = @localized_branch
        @localized_branch = locale
        localized([locale], omit_locale: @omit_locale ) do
          yield
        end
        @localized_branch = old
      end
    end

    # Set we do not want to localize next resource
    def skip_localization
      old = @skip_localization
      @skip_localization = @localized_branch ? nil : true
      yield
      @skip_localization = old
    end



    # Overrides match method
    # Two variants of match are supported now
    #   match 'about' => 'pages#about', :as => 'about'
    #   match 'about', :to => 'pages#about'
    #   match 'home', :to => 'pages#home', :as => 'main' # Route name overridden to 'main'
    def match(*args)
      # Localize simple match only if there is no resource scope.
      if @locales and (args.size >= 1) and !parent_resource and
             args.last.is_a?(Hash) # In both variants Hash should be present as last parameter

        # Make deep copy of last argument (Hash)
        options = Marshal.load(Marshal.dump(args.last)) # Dump is dirty but how to make deep cloning easily ? :/

        # Now handle parameters
        if (args.first.is_a?(Hash))
          path, to = options.find { |name, value| name.is_a?(String) }
          options.merge!(:to => to).delete(path)
        else
          path = args[0]
          options[:as] ||= path
        end

        if (options[:as])
          @locales.each do |locale|
            mapping = LocalizedMapping.new(locale, @set, @scope, path, options)
            if mapping.localizable?
              puts("[I18n] > localize %-10s: %40s (%s) => %s" % ['route', options[:as], locale, mapping.path]) if @i18n_verbose
              @set.add_route(*mapping.to_route)
            end
          end

          # Now, create the real match :
          return set_localizable_route(options[:as]) do
            super
          end
        end
      end

      super
    end

    def create_globalized_resources(type, *resources, &block)
      #puts "#{' ' * nested_deep}Call #{type} : #{resources.inspect} (#{@locales.inspect}) (#{@localized_branch}) (#{@skip_localization})"

      @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(nested_deep: [])) unless @scope[:nested_deep]  # total hack :)
      @scope[:nested_deep] << 1

      cur_scope = nil
      if @locales
        localized = localized_resources(type, *resources, &block) if !@skip_localization

        ## We do not translate if we are in a translation branch :
        return if localized and nested_deep > 0

        # Set the current standard resource in order to customize url helper :
        if !@localized_branch
          r = resource_from_params(type, *resources)
          parent_resource.inspect
          cur_scope = (parent_resource and parent_resource.name == r.name) ? parent_resource : r
        end
      end

      set_localizable_route(cur_scope) do
        skip_localization do
          #puts "#{' ' * nested_deep} \\- Call original #{type} : for #{resources.inspect}}"
          send("#{type}_without_i18n_routing".to_sym, *resources, &block)
        end
      end

      @scope[:nested_deep].pop
    end



    module MapperExtensions

      def resource(*resources, &block)
        create_globalized_resources(:resource, *resources, &block)
      end

      def resources(*resources, &block)
        create_globalized_resources(:resources, *resources, &block)
      end

      # from rails 5.0.0.1, actionpack/lib/action_dispatch/routing/mapper.rb, line 1269
      def resource_without_i18n_routing(*resources, &block)
        options = resources.extract_options!.dup

        if apply_common_behavior_for(:resource, resources, options, &block)
          return self
        end

        with_scope_level(:resource) do
          options = apply_action_options options
          resource_scope(ActionDispatch::Routing::Mapper::SingletonResource.new(resources.pop, api_only?, @scope[:shallow], options)) do
            yield if block_given?

            concerns(options[:concerns]) if options[:concerns]

            collection do
              post :create
            end if parent_resource.actions.include?(:create)

            new do
              get :new
            end if parent_resource.actions.include?(:new)

            set_member_mappings_for_resource
          end
        end

        self
      end

      # from rails 5.0.0.1, actionpack/lib/action_dispatch/routing/mapper.rb, line 1430
      def resources_without_i18n_routing(*resources, &block)
        options = resources.extract_options!.dup

        if apply_common_behavior_for(:resources, resources, options, &block)
          return self
        end

        with_scope_level(:resources) do
          options = apply_action_options options
          resource_scope(ActionDispatch::Routing::Mapper::Resource.new(resources.pop, api_only?, @scope[:shallow], options)) do
            yield if block_given?

            concerns(options[:concerns]) if options[:concerns]

            collection do
              get  :index if parent_resource.actions.include?(:index)
              post :create if parent_resource.actions.include?(:create)
            end

            new do
              get :new
            end if parent_resource.actions.include?(:new)

            set_member_mappings_for_resource
          end
        end

        self
      end

      # On Routing::Mapper initialization (when doing Application.routes.draw do ...)
      # prepare routing system to be i18n ready
      def initialize(*args)
        super(*args)

        # Extends the current RouteSet in order to define localized helper for named routes
        # When calling define_url_helper, it calls define_localized_url_helper too.
        if !@set.named_routes.respond_to?(:define_localized_url_helper)
          @set.named_routes.class_eval <<-END_EVAL, __FILE__, __LINE__ + 1
            alias_method :localized_define_url_helper, :define_url_helper
            def define_url_helper(mod, route, name, opts, route_key, url_strategy)
              localized_define_url_helper(mod, route, name, opts, route_key, url_strategy)
              define_localized_url_helper(mod, route, name, opts, route_key, url_strategy)
            end
          END_EVAL

          @set.named_routes.extend I18nRouting::NamedRouteCollection
        end
      end

      # Here we redefine some methods, in order to handle
      # correct path_names translation on the fly
      [:map_method, :member, :collection].each do |m|
        define_method "#{m}".to_sym do |*args, &block|
          if @localized_branch and @scope[:i18n_scope_level_resource] and @scope[:i18n_real_resource_name]
            o = @scope[:scope_level_resource]
            @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(scope_level_resource: @scope[:i18n_scope_level_resource]))

            pname = @scope[:path_names] || {}
            flattened_args = args.flatten
            i = 1
            while i < flattened_args.size and (String === flattened_args[i] or Symbol === flattened_args[i])
              pname[flattened_args[i]] = flattened_args[i]
              i += 1
            end

            scope(:path_names => I18nRouting.path_names(@scope[:i18n_real_resource_name], {:path_names => pname})) do
              super *args, &block
            end
            @scope.instance_variable_set(:@hash, @scope.instance_variable_get(:@hash).merge(scope_level_resource: o))
            return
          end

          super *args, &block
        end
      end

    end


    # Alias methods in order to handle i18n routes
    def self.included(mod)
      mod.prepend(MapperExtensions)
    end

  end

  # Used for localize simple named routes
  class LocalizedMapping < ActionDispatch::Routing::Mapper::Mapping
    attr_reader :path

    def initialize(locale, set, scope, path, options)

      super(set, scope, path.clone, options ? options.clone : nil)
      stored_locale = I18n.locale

      # try to get translated path :
      I18n.locale = locale
      ts = @path.gsub(/^\//, '')
      append_format = ts =~ /\(\.:format\)/
      ts.gsub!('(.:format)', '')

      tp = @options[:as] && I18nRouting.translation_for(@options[:as], :named_routes) ||
          !ts.blank? && I18nRouting.translation_for(ts, :named_routes_path) || ts

      localized_scope = I18nRouting.translation_for(@scope[:path].gsub(/\//, ''), :scopes) if @scope[:path]
      path = localized_scope ? '/' << localized_scope : @scope[:path]
      @localized_path = File.join((path || ''), tp).gsub(/\/$/, '')

      # If a translated path exists, set localized infos
      if !@localized_path.blank? and @localized_path != @path
        #@options[:controller] ||= @options[:as]
        @options[:as] = "#{I18nRouting.locale_escaped(locale)}_#{@options[:as]}"
        @path = @localized_path
        @path = "#{@path}(.:format)" if append_format
        @options[:constraints] = @options[:constraints] ? @options[:constraints].dup : {}
        @options[:constraints][:locale] = locale.to_s
        @options[:anchor] = true
        # Force the recomputation of the requirements with the new values
        @requirements = nil
      else
        @localized_path = nil
      end
      I18n.locale = stored_locale
    end

    # Return true if this route is localizable
    def localizable?
      @localized_path != nil
    end
  end

  module NamedRouteCollection
    attr_reader :localizable

    def set_localizable_route(localizable)
      @localizable = localizable
    end

    # Alias named route helper in order to check if a localized helper exists
    # If not use the standard one.
    def define_localized_url_helper(mod, route, name, opts, route_key, url_strategy)
      if n = localizable
        # rails 4 fix
        selector = name
        name = name.to_s.sub(/_(path|url)/,'').to_sym
        # rails 4 fix end

        rlang = if n.kind_of?(ActionDispatch::Routing::Mapper::Resources::Resource) and i = name.to_s.rindex("_#{n.plural}")
                  "#{selector.to_s[0, i]}_glang_#{n.plural}#{selector.to_s[i + "_#{n.plural}".size, selector.to_s.size]}"
                elsif n.kind_of?(ActionDispatch::Routing::Mapper::Resources::Resource) and i = name.to_s.rindex("_#{n.singular}")
                  "#{selector.to_s[0, i]}_glang_#{n.singular}#{selector.to_s[i + "_#{n.singular}".size, selector.to_s.size]}"
                else
                  "glang_#{selector}"
                end

        mod.module_eval do
          alias_method "localized_#{selector}", selector

          define_method selector do |*args|
            selector_g = "#{rlang}".gsub('glang', I18nRouting.locale_escaped(I18n.locale.to_s)).to_sym

            #puts "Call routes : #{selector} => \#{selector_g} (\#{I18n.locale}) "
            if respond_to? selector_g and selector_g != selector.to_sym
              send(selector_g, *args)
            else
              send("localized_#{selector}", *args)
            end
          end
        end

      end
    end
  end

  # Journey::Route module
  # Exists in order to use appropriate localized route when using url_for
  module JourneyRoute

    module I18nExtenisons
      # During route initialization, if a condition locale is present
      # Delete it, store it in @locale, and add it to @defaults
      def initialize(name, app, path, constraints, required_defaults, defaults, request_method_match, precedence, internal = false)
        @locale = if constraints.key?(:locale)
          c = constraints.delete(:locale)
          # In rails 3.0 it's a regexp otherwise it's a string, so we need to call source on the regexp
          (c.respond_to?(:source) ? c.source : c).to_sym
        else
          nil
        end
        super(name, app, path, constraints, required_defaults, defaults, request_method_match, precedence, internal)
      end

      # Return low score for routes that don't match the current locale
      def score constraints
        return -1 if @locale && @locale != I18n.locale.to_sym
        super constraints
      end
    end

    def self.included(mod)
      mod.prepend(I18nExtenisons)
    end

  end
end

ActionDispatch::Routing::Mapper.send :include, I18nRouting::Mapper
ActionDispatch::Journey::Route.send  :include, I18nRouting::JourneyRoute
