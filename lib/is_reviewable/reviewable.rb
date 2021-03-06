require_relative 'support'

module IsReviewable
  module Reviewable
    def self.included(base) #:nodoc:
      base.class_eval do
        extend ClassMethods
        include InstanceMethods
      end
      
      # Checks if this object reviewable or not.
      #
      def reviewable?; false; end
      alias :is_reviewable? :reviewable?
    end

    DEFAULTS = {
        :accept_ip => false,
        :scale => 1..5
      }.freeze

    module ClassMethods

      DEFAULTS = {
        accept_ip: false,
        scale:     1..5
      }.freeze

      # Examples:
      #
      #   is_reviewable :by => :user, :scale => 0..5, :total_precision => 2
      #
      def is_reviewable(*args)
        options = args.extract_options!
        options.reverse_merge!(
          by:        nil,
          scale:     options[:values] || options[:range] || DEFAULTS[:scale],
          accept_ip: options[:anonymous] || DEFAULTS[:accept_ip] # i.e. also accepts unique IPs as reviewer
        )

        scale = options[:scale]
        options[:steps] = scale.last - scale.first + 1 if options[:step].blank? && options[:steps].blank?

        options[:total_precision] ||= options[:average_precision] || scale.first.to_s.split('.').last.size # == 1
        
        # Check for incorrect input values, and handle ranges of floats with help of :step. E.g. :scale => 1.0..5.0.
        
        if scale.is_a?(::Range) && scale.first.is_a?(::Float)
          options[:step] = (scale.last - scale.first) / (options[:steps] - 1) if options[:step].blank?
          options[:scale] = scale.first.step(scale.last, options[:step]).collect { |value| value }
        else
          options[:scale] = scale.to_a.collect! { |v| v.to_f }
        end
        raise InvalidConfigValueError, ':scale/:range/:values must consist of numeric values only.' unless options[:scale].all? { |v| v.is_a?(::Numeric) }
        raise InvalidConfigValueError, ':total_precision must be an integer.' unless options[:total_precision].is_a?(::Fixnum)
        
        # Reviewer class(es).
        options[:reviewer_classes] = [*options[:by]].collect do |class_name|
          begin
            class_name.to_s.singularize.classify.constantize
          rescue NameError => e
            raise InvalidReviewerError, "Reviewer class #{class_name} not defined, needs to be defined. #{e}"
          end
        end
        
        # Assocations: Reviewer class(es) (e.g. User, Account, ...).
        options[:reviewer_classes].each do |reviewer_class|
          if ::Object.const_defined?(reviewer_class.name.to_sym)
            reviewer_class.class_eval do

              has_many :reviews, foreign_key: :reviewer_id, class_name: Review.name

              def reviewables
                Review.preload(:reviewable).by(self).collect! { |review| review.reviewable }
              end
            end
          end
        end

        # Class definition

        has_many :reviews, as: :reviewable, dependent: :delete_all, class_name: Review.name

        scope :reviewed, -> {
          if reviewable_caching_field?(:average_rating) && reviewable_caching_field?(:total_reviews)
            where("#{cached_attribute(:average_rating)} > ? AND #{cached_attribute(:total_reviews)} > ?", 0, 0)
          else
            joins(:reviews)
          end
        }

        # TODO should not include not reviewed if have reviewable_caching_field?
        scope :most_rated, -> {
          if reviewable_caching_field?(:average_rating)
            reviewed.order("#{cached_attribute(:average_rating)} DESC")
          else
            reviewed.group("#{table_name}.#{primary_key}").order('SUM(rating) DESC')
          end
        }

        # TODO should not include not reviewed if have reviewable_caching_field?
        scope :most_voted, -> {
          if reviewable_caching_field?(:total_reviews)
            reviewed.order("#{cached_attribute(:total_reviews)} DESC")
          else
            reviewed.group("#{table_name}.#{primary_key}").order('SUM(1) DESC')
          end
        }

        def reviewers
          Review.preload(:reviewer).on(self).collect(&:reviewer)
        end

        before_create :init_reviewable_caching_fields

        # Save the initialized options for this class.

        class_attribute :is_reviewable_options

        self.is_reviewable_options= options
      end
      
      # Checks if this object reviewable or not.
      #
      def reviewable?
        self.respond_to?(:is_reviewable_options, true)
      end
      alias :is_reviewable? :reviewable?
      
      # The rating scale used for this reviewable class.
      #
      def reviewable_scale
        self.is_reviewable_options[:scale]
      end
      alias :rating_scale :reviewable_scale
      
      # The rating value precision used for this reviewable class.
      #
      # Using Rails default behaviour:
      #
      #   Float#round(<precision>)
      #
      def reviewable_precision
        self.is_reviewable_options[:total_precision]
      end
      alias :rating_precision :reviewable_precision

      protected

      def reviewable_caching_field?(field)
        attribute_method?(cached_attribute(field))
      end

      def cached_attribute(field)
        "cached_#{field.to_s}"
      end
        
      # Check if the requested reviewer object is a valid reviewer.
      #
      def validate_reviewer(identifiers)
        raise InvalidReviewerError, 'Argument can\'t be nil: no reviewer object or IP provided.' if identifiers.blank?
        reviewer = identifiers[:by] || identifiers[:reviewer] || identifiers[:user] || identifiers[:ip]
        is_ip = Support.is_ip?(reviewer)
        reviewer = reviewer.to_s.strip if is_ip

        raise InvalidReviewerError, "Reviewer is of wrong type: #{reviewer.inspect}." unless Support.is_active_record?(reviewer) || is_ip
        raise InvalidReviewerError, 'Reviewing based on IP is disabled.' if is_ip && !self.is_reviewable_options[:accept_ip]

        reviewer
      end
        
    end
    
    module InstanceMethods
      
      # Checks if this object reviewable or not.
      #
      def reviewable?
        self.class.reviewable?
      end
      alias :is_reviewable? :reviewable?
      
      # The rating scale used for this reviewable class.
      #
      def reviewable_scale
        self.class.reviewable_scale
      end
      alias :rating_scale :reviewable_scale
      
      # The rating value precision used for this reviewable class.
      #
      def reviewable_precision
        self.class.reviewable_precision
      end
      alias :rating_precision :reviewable_precision
      
      # Reviewed at datetime.
      #
      def reviewed_at
        self.created_at if self.respond_to?(:created_at)
      end
      
      # Calculate average rating for this reviewable object.
      # 
      def average_rating(recalculate = false)
        if !recalculate && self.reviewable_caching_field?(:average_rating)
          self.cached_average_rating
        else
          Review.on(self).with_a_rating.average(:rating).to_f.round(self.is_reviewable_options[:total_precision])
        end
      end
      
      # Calculate average rating for this reviewable object within a domain of reviewers.
      #
      def average_rating_by(identifiers)
        # FIXME: Only count non-nil ratings, i.e. See "average_rating".
        self.reviewer_conditions(identifiers).on(self).average(:rating).
          to_f.round(self.is_reviewable_options[:total_precision])
      end
      
      # Get the total number of reviews for this object.
      #
      def total_reviews(recalculate = false)
        if !recalculate && self.reviewable_caching_field?(:total_reviews)
          self.cached_total_reviews
        else
          Review.on(self).count
        end
      end
      alias :number_of_reviews :total_reviews
      
      # Is this object reviewed by anyone?
      #
      def reviewed?
        self.total_reviews > 0
      end
      alias :is_reviewed? :reviewed?
      
      # Check if an item was already reviewed by the given reviewer or ip.
      #
      # === identifiers hash:
      # * <tt>:ip</tt> - identify with IP
      # * <tt>:reviewer/:user/:account</tt> - identify with a reviewer-model (e.g. User, ...)
      #
      def reviewed_by?(identifiers)
        self.reviews.merge(self.reviewer_conditions(identifiers)).exists?
      end
      alias :is_reviewed_by? :reviewed_by?
      
      # Get review already reviewed by the given reviewer or ip.
      #
      def review_by(identifiers)
        self.reviews.merge(self.reviewer_conditions(identifiers)).first
      end
      
      # View the object with and identifier (user or ip) - create new if new reviewer.
      #
      # === identifiers_and_options hash:
      # * <tt>:reviewer/:user/:account</tt> - identify with a reviewer-model or IP (e.g. User, Account, ..., "128.0.0.1")
      # * <tt>:rating</tt> - Review rating value, e.g. 3.5, "3.5", ... (optional)
      # * <tt>:body</tt> - Review text body, e.g. "Lorem *ipsum*..." (optional)
      # * <tt>:*</tt> - Any custom review field, e.g. :reviewer_mood => "angry" (optional)
      #
      def review!(identifiers_and_options)
        begin
          reviewer = self.validate_reviewer(identifiers_and_options)
          review = self.review_by(identifiers_and_options)

          # Except for the reserved fields, any Review-fields should be be able to update.
          review_values = identifiers_and_options.except(*Review::ASSOCIATIVE_FIELDS)
          review_values[:rating] = review_values[:rating].to_f if review_values[:rating].present?
          
          if review_values[:rating].present? && !self.valid_rating_value?(review_values[:rating])
            raise InvalidReviewValueError, "Invalid rating value: #{review_values[:rating]} not in [#{self.rating_scale.join(', ')}]."
          end
          
          unless review.present?
            # An un-existing reviewer of this reviewable object => Create a new review.
            review = Review.new do |r|
              r.reviewable_id   = self.id
              r.reviewable_type = self.class.name
              
              if Support.is_active_record?(reviewer)
                r.reviewer_id   = reviewer.id
                r.reviewer_type = reviewer.class.name
              else
                r.ip = reviewer
              end
            end

            self.reviews << review
          end
          
          # Update non-association attributes, such as rating, body (the review text), and any custom fields.
          review.attributes = review_values.slice(*review.attribute_names.collect { |an| an.to_sym })
          
          # Save review and cachable data.
          review.save && self.update_cache!
          review
        rescue InvalidReviewerError, InvalidReviewValueError => e
          raise e
        rescue Exception => e
          raise RecordError, "Could not create/update review #{review.inspect} by #{reviewer.inspect}: #{e}"
        end
      end
      
      # Remove the review of this reviewer from this object.
      #
      def unreview!(identifiers)
        review = self.review_by(identifiers)

        if review && review.destroy
          self.update_cache!
        else
          raise RecordError, "Could not un-review #{review.inspect}"
        end
      end
      
      protected
        
      # Update cache fields if available/enabled.
      #
      def update_cache!
        if self.reviewable_caching_field?(:total_reviews)
          # self.cached_total_reviews += 1 if review.new_record?
          self.cached_total_reviews = self.total_reviews(true)
        end
        if self.reviewable_caching_field?(:average_rating)
          # new_rating = review.rating - (old_rating || 0)
          # self.cached_average_rating = (self.cached_average_rating + new_rating) / self.cached_total_reviews.to_f
          self.cached_average_rating = self.average_rating(true)
        end
        self.save(validate: false) if self.changed?
      end

      # Checks if a certain value is a valid rating value for this reviewable object.
      #
      def valid_rating_value?(value_or_values)
        value_or_values = [*value_or_values]
        value_or_values.size == (value_or_values & self.rating_scale).size
      end
      alias :valid_rating_values? :valid_rating_value?

      # Checks if there are any cached fields for this reviewable class.
      def reviewable_caching_field?(field)
        self.class.send(:reviewable_caching_field?, field)
      end

      # Initialize any cached fields.
      #
      def init_reviewable_caching_fields
        self.cached_total_reviews = 0 if self.reviewable_caching_field?(:total_reviews)
        self.cached_average_rating = 0.0 if self.reviewable_caching_field?(:average_rating)
      end

      # Generate query conditions.
      #
      def reviewer_conditions(identifiers)
        reviewer = self.validate_reviewer(identifiers)

        if Support.is_active_record?(reviewer)
          Review.by(reviewer)
        else
          Review.with_ip(reviewer.to_s)
        end
      end

      def validate_reviewer(identifiers)
        self.class.send(:validate_reviewer, identifiers)
      end
        
    end
    
  end
end

ActiveRecord::Base.send(:include, IsReviewable::Reviewable)