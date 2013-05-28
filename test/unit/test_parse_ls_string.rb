require sprintf('%s/../../path_helper', File.dirname(File.expand_path(__FILE__)))

# this is based on RHEL output, how cross compatible is this?

require 'rouster'
require 'rouster/tests'
require 'test/unit'

class TestPut < Test::Unit::TestCase

  def setup

    @app = Rouster.new(:name => 'app')

  end

  def test_readable_by_all
    str = "-r--r--r-- 1 root root 199 May 27 22:51 /readable\n"

    expectation = {
      :directory?  => false,
      :file?       => true,
      :mode        => '0444',
      :owner       => 'root',
      :group       => 'root',
      :size        => '199',
      :executable? => [false, false, false],
      :readable?   => [true, true, true],
      :writeable?  => [false, false, false]
    }

    res = @app.parse_ls_string(str)

    assert_equal(expectation, res)
  end

  def test_executable_by_all
    str = "-rwxrwxrwx 1 root root 199 May 27 22:51 /executable\n"

    expectation = {
        :directory?  => false,
        :file?       => true,
        :mode        => '0777',
        :owner       => 'root',
        :group       => 'root',
        :size        => '199',
        :executable? => [true, true, true],
        :readable?   => [true, true, true],
        :writeable?  => [true, true, true]
    }

    res = @app.parse_ls_string(str)

    assert_equal(expectation, res)
  end

  def test_writable_by_all
    str = "-r--r--r-- 1 root root 199 May 27 22:51 /readable\n"

    expectation = {
        :directory?  => false,
        :file?       => true,
        :mode        => '0666',
        :owner       => 'root',
        :group       => 'root',
        :size        => '199',
        :executable? => [false, false, false],
        :readable?   => [true, true, true],
        :writeable?  => [true, true, true]
    }

    res = @app.parse_ls_string(str)

    assert_equal(expectation, res)
  end

  def test_dir_detection
    dir_str = "drwxrwxrwt 5 root root 4096 May 28 00:26 /tmp/\n"
    file_str  = "-rw-r--r-- 1 root    root      906 Oct  2  2012 grub.conf\n"

    dir  = @app.parse_ls_string(dir_str)
    file = @app.parse_ls_string(file_str)

    assert_equal(true,  dir[:directory?])
    assert_equal(false, dir[:file?])

    assert_equal(false, file[:directory?])
    assert_equal(true,  file[:file?])

  end

  def teardown
    # noop
  end

end
