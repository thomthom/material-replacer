#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'sketchup.rb'
begin
  require 'TT_Lib2/core.rb'
rescue LoadError => e
  module TT
    if @lib2_update.nil?
      url = 'http://www.thomthom.net/software/sketchup/tt_lib2/errors/not-installed'
      options = {
        :dialog_title => 'TT_Lib² Not Installed',
        :scrollable => false, :resizable => false, :left => 200, :top => 200
      }
      w = UI::WebDialog.new( options )
      w.set_size( 500, 300 )
      w.set_url( "#{url}?plugin=#{File.basename( __FILE__ )}" )
      w.show
      @lib2_update = w
    end
  end
end


#-------------------------------------------------------------------------------

if defined?( TT::Lib ) && TT::Lib.compatible?( '2.7.0', 'Material Replacer' )

module TT::Plugins::MaterialReplacer


  ### MENU & TOOLBARS ### ------------------------------------------------------

  unless file_loaded?( __FILE__ )
    m = TT.menu('Tools')
    m.add_item('Material Replacer')  { self.activate_tool }
  end


  ### MAIN SCRIPT ### ----------------------------------------------------------

  def self.activate_tool
    my_tool = MatReplacer.new
    Sketchup.active_model.tools.push_tool(my_tool)
  end

  class MatReplacer

    def initialize
      @picked = nil
      @m_org = nil
      @state = 0

      @c_dropper = TT::Cursor.get_id( :dropper )
      @c_dropper_err = TT::Cursor.get_id( :dropper_invalid )
    end

    def activate
      @picked = nil
      @m_org = nil
      @state = 0
      @pos = [0,0,0]
      @drawn = false
      update_ui()

      @debug = nil
    end

    def update_ui
      Sketchup.set_status_text('Pick a material to replace.')
    end

    def resume(view)
      update_ui()
    end

    def deactivate(view)
      view.invalidate if @drawn
    end

    def onMouseMove(flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)

      picked = (ph.picked_face.nil?) ? (ph.picked_edge.nil?) ? ph.best_picked : ph.picked_edge : ph.picked_face

      index = 0
      for i in 1..ph.count
        if ph.element_at(i) == picked
          index = i
          break
        end
      end
      path = ph.path_at(index)
      t = ph.transformation_at(index)

      if path.nil?
        @picked = nil
      else
        @picked = nil
        # Get picked face global normal
        n = ( picked.is_a?(Sketchup::Face) ) ? picked.normal.transform(t).normalize : nil
        # Travel down the path to work out the visible material
        path.each { |e|
          next unless e.respond_to?(:material)
          if e.is_a?(Sketchup::Face)
            c = Sketchup.active_model.active_view.camera.direction
            m = (c % n > 0) ? e.back_material : e.material
            next if m.nil?
            @picked = m
          else
            next if e.material.nil?
            @picked = e.material
          end
        }

        # DEBUG
        #@path = path
        #@debug = n
      end

      @pos = [x,y,0]
      view.invalidate
    end

    def onLButtonUp(flags, x, y, view)
      if @state == 0
        @m_org = @picked
        @state = 1

        o_name = (@m_org.nil?) ? 'Default' : @m_org.display_name
        Sketchup.set_status_text("Pick another material to replace #{o_name}.")
      else
        return if @picked == @m_org

        model = Sketchup.active_model

        TT::Model.start_operation('Replace Materials')
        Sketchup.set_status_text('Replacing materials. Please wait...')

        model.entities.each { |e|
          if e.respond_to?(:material)
            e.material = @picked if e.material == @m_org
          end
          if e.respond_to?(:back_material)
            e.back_material = @picked if e.back_material == @m_org
          end
        }
        model.definitions.each { |d|
          next if d.image?
          d.entities.each { |e|
            if e.respond_to?(:material)
              e.material = @picked if e.material == @m_org
            end
            if e.respond_to?(:back_material)
              e.back_material = @picked if e.back_material == @m_org
            end
          }
        }

        model.commit_operation

        activate
      end
    end

    TEXT_OPTIONS = {
      font: "Tahoma",
      pixel_size: 13, # Use :size for SketchUp 2024.0 and older.
      color: Sketchup::Color.new(20, 20, 20),
      # :bold => true,
      :vertical_align => TextVerticalAlignBoundsTop
    }
    if Sketchup.version.to_i < 25
      # This is points on Windows and pixels on macOS.
      pixels = TEXT_OPTIONS[:pixel_size]
      points = pixels * 0.75
      TEXT_OPTIONS[:size] = Sketchup.platform == :platform_win ? points : pixels
      TEXT_OPTIONS.delete(:pixel_size)
    end

    TEXT_BACKGROUND = Sketchup::Color.new(220, 220, 220, 230)

    def draw(view)
      pos = @pos.offset([35, -20])

      str = ''
      if @state == 0
        p_name = (@picked.nil?) ? 'Default' : @picked.display_name
        str = "Replace #{p_name} ..."
      else
        o_name = (@m_org.nil?) ? 'Default' : @m_org.display_name
        p_name = (@picked.nil?) ? 'Default' : @picked.display_name
        str = "Replace #{o_name}\nwith #{p_name}"
      end

      if view.respond_to?(:text_bounds)
        bounds = view.text_bounds(pos, str, TEXT_OPTIONS)
        points = bounds_to_polygon(offset_bounds(bounds, 3))
        view.drawing_color = TEXT_BACKGROUND
        view.draw2d(GL_QUADS, points, TEXT_OPTIONS)
      end
      if Sketchup.version.to_i < 16
        view.draw_text(pos, str)
      else
        view.draw_text(pos, str, TEXT_OPTIONS)
      end

      # DEBUG
      #pos[1] += 40
      #view.draw_text(pos, "#{@debug.inspect}\n#{@path.inspect}")

      @drawn = true
    end

    def onSetCursor
      if @state == 1 && @picked == @m_org
        UI.set_cursor(@c_dropper_err)
      else
        UI.set_cursor(@c_dropper)
      end
    end

    private

    # @param [Geom::Bounds2d] bounds
    # @param [Integer] offset Number of pixels to offset the bounds by.
    # @return [Geom::Bounds2d] New bounds offset by the specified amount.
    def offset_bounds(bounds, offset)
      x1, y1 = bounds.upper_left.to_a
      x2, y2 = bounds.lower_right.to_a
      Geom::Bounds2d.new(
        Geom::Point2d.new(x1 - offset, y1 - offset),
        Geom::Point2d.new(x2 + offset, y2 + offset)
      )
    end

    # @param [Geom::Bounds2d] bounds
    # @return [Array<Geom::Point3d>] Array of points representing the corners of the bounds.
    def bounds_to_polygon(bounds)
      x1, y1 = bounds.upper_left.to_a
      x2, y2 = bounds.lower_right.to_a
      points = [
        Geom::Point3d.new(x1, y1),
        Geom::Point3d.new(x1, y2),
        Geom::Point3d.new(x2, y2),
        Geom::Point3d.new(x2, y1),
      ]
    end

  end # class

  ### DEBUG ### ----------------------------------------------------------------

  # @note Debug method to reload the plugin.
  #
  # @example
  #   TT::Plugins::MaterialReplacer.reload
  #
  # @param [Boolean] tt_lib Reloads TT_Lib2 if +true+.
  #
  # @return [Integer] Number of files reloaded.
  # @since 1.0.0
  def self.reload( tt_lib = false )
    original_verbose = $VERBOSE
    $VERBOSE = nil
    TT::Lib.reload if tt_lib
    # Core file (this)
    load __FILE__
    # Supporting files
    if defined?( PATH ) && File.exist?( PATH )
      x = Dir.glob( File.join(PATH, '*.{rb,rbs}') ).each { |file|
        load file
      }
      x.length + 1
    else
      1
    end
  ensure
    $VERBOSE = original_verbose
  end

end # module

end # if TT_Lib

#-------------------------------------------------------------------------------

file_loaded( __FILE__ )

#-------------------------------------------------------------------------------
