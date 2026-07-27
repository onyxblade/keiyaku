# frozen_string_literal: true

require_relative "../names"

module Keiyaku
  class Emitter
    # What the document says a caller has to send, in the runtime's own
    # vocabulary. A scheme nobody can implement is kept out of the table rather
    # than out of the document: it only costs the operations that actually
    # require it, and an operation that documents mutualTLS *or* an API key is
    # one this client can still call.
    #
    # The schemes arrive already resolved, because a $ref is the Emitter's
    # business and this has no document to look one up in.
    class Security
      def initialize(schemes:, default:, notes:)
        @notes = notes
        @schemes = {}      # the document's name for a scheme => how the runtime is told to send it
        @unsupported = {}  # the document's name => what it is, for the message that refuses it

        schemes.each do |name, scheme|
          if (declaration = declaration_for(scheme))
            @schemes[name] = declaration
          else
            @unsupported[name] = [scheme["type"], scheme["scheme"]].compact.join(" ")
          end
        end

        @default = requirement_for(default)
        # What an operation that says nothing about security gets. An
        # alternative naming a scheme nothing can send is not one of them, and
        # the operations that are left with none are refused one by one.
        @usable = (@default || []).select { satisfiable?(_1) }
      end

      # What the operation sends, as the DSL spells it — or nil where that is
      # the client's default, which is declared once at the top of the class
      # and does not need repeating on the method.
      def source_for(name, op)
        alternatives = for_operation(name, op)
        requirement_source(alternatives) unless alternatives == @usable
      end

      # The schemes the whole document has, and the requirement that holds
      # wherever an operation does not state one of its own. Both belong to the
      # client rather than to any of its methods.
      def table
        return "" if @schemes.empty?

        declarations = @schemes.map { |name, declaration| "#{scheme_key(name)} #{declaration}" }
        default = @usable.empty? ? "" : ", default: #{requirement_source(@usable)}"
        "    security({ #{declarations.join(", ")} }#{default})\n"
      end

      private

      def satisfiable?(schemes) = schemes.all? { @schemes.key?(_1) }

      def declaration_for(scheme)
        case [scheme["type"], scheme["scheme"]&.downcase, scheme["in"]]
        in ["http", "bearer", _] then ":bearer"
        in ["http", "basic", _] then ":basic"
        # An OAuth 2 access token is a bearer token, and so is the one an
        # OpenID Connect flow ends with; where it goes on the request is RFC
        # 6750 rather than a guess. Obtaining it is the caller's business —
        # nothing here runs a flow, which is also why the scopes a requirement
        # lists say nothing this client could act on.
        in ["oauth2" | "openIdConnect", _, _] then ":bearer"
        in ["apiKey", _, "header"] then "{ header: #{scheme["name"].inspect} }"
        in ["apiKey", _, "query"] then "{ query: #{scheme["name"].inspect} }"
        in ["apiKey", _, "cookie"] then "{ cookie: #{scheme["name"].inspect} }"
        else nil
        end
      end

      # A security requirement is a list of alternatives, any one of which is
      # enough, each naming schemes that all have to be satisfied. `security: []`
      # is the operation that takes no credentials, which is not the same as the
      # key being absent — that one takes the document's.
      def requirement_for(declared) = declared&.map(&:keys)

      # What one operation actually requires, with the alternatives the client
      # could not satisfy dropped. Only when none are left is the operation
      # refused.
      def for_operation(name, op)
        alternatives = op.key?("security") ? requirement_for(op["security"]) : @default
        return [] if alternatives.nil? || alternatives.empty?

        usable, rejected = alternatives.partition { satisfiable?(_1) }

        rejected.each do |schemes|
          unknown = schemes.reject { @schemes.key?(_1) || @unsupported.key?(_1) }
          raise Impossible, "requires #{unknown.first.inspect}, which the document does not declare" if unknown.any?
        end

        if usable.empty?
          needed = rejected.flatten.uniq.map { "#{_1} (#{@unsupported[_1]})" }
          raise Impossible, "requires #{needed.join(" or ")}, which the runtime has no way to send"
        end
        if rejected.any?
          @notes << "#{name}: sends #{usable.first.join(" and ")}; " \
                    "the document also allows #{rejected.map { _1.join(" and ") }.join(" or ")}, which is not supported"
        end

        usable
      end

      # The shortest spelling of a requirement: a bare scheme name where there is
      # one alternative naming one scheme, `false` where there is no requirement
      # at all, and the alternatives written out where there is a choice.
      def requirement_source(alternatives)
        return "false" if alternatives.empty?
        return alternatives.first.first.to_sym.inspect if alternatives.size == 1 && alternatives.first.size == 1

        "[#{alternatives.map { |schemes| "[#{schemes.map { _1.to_sym.inspect }.join(", ")}]" }.join(", ")}]"
      end

      # The document's own name for the scheme, which is what credentials are
      # given by, so it is left exactly as the document spells it.
      def scheme_key(name)
        name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) ? "#{name}:" : "#{name.inspect}:"
      end
    end
  end
end
