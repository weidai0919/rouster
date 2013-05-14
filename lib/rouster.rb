require 'rubygems'
require 'json'

$LOAD_PATH << '/Applications/Vagrant/embedded/gems/gems/vagrant-1.0.5/lib/'
require 'vagrant'

require 'rouster/vagrant'

class Rouster
  VERSION = 0.1

  # custom exceptions -- what else do we want them to include/do?
  class FileTransferError    < StandardError; end # thrown by get() and put()
  class InternalError        < StandardError; end # thrown by most (if not all) Rouster methods
  class LocalExecutionError  < StandardError; end # thrown by _run()
  class RemoteExecutionError < StandardError; end # thrown by run()
  class SSHConnectionError   < StandardError; end # thrown by available_via_ssh() -- and potentially _run()

  attr_reader :deltas, :_env, :exitcode, :facts, :log, :name, :output, :passthrough, :sudo, :vagrantfile, :verbosity, :_vm, :_vm_config

  # TODO use the Vagranty .merge pattern for defaults
  def initialize(opts = nil)
    # process hash keys passed
    @name        = opts[:name] # since we're constantly calling .to_sym on this, might want to just start there
    @passthrough = opts[:passthrough].nil? ? false : opts[:passthrough]
    @sshkey      = opts[:sshkey]
    @vagrantfile = opts[:vagrantfile].nil? ? traverse_up(Dir.pwd, 'Vagrantfile', 5) : opts[:vagrantfile]
    @verbosity   = opts[:verbosity].is_a?(Integer) ? opts[:verbosity] : 5

    if opts.has_key?(:sudo)
      @sudo = opts[:sudo]
    elsif @passthrough.eql?(true)
      @sudo = false
    else
      @sudo = true
    end

    @output      = Array.new
    @sshinfo     = Hash.new
    @deltas      = Hash.new # should probably rename this, but need container for deltas.rb/get_*
    @exitcode    = nil

    # set up logging
    require 'log4r/config'
    Log4r.define_levels(*Log4r::Log4rConfig::LogLevels)

    @log            = Log4r::Logger.new(sprintf('rouster:%s', @name))
    @log.outputters = Log4r::Outputter.stderr
    @log.level      = @verbosity # DEBUG (1) < INFO (2) < WARN < ERROR < FATAL (5)

    unless File.file?(@vagrantfile)
      raise InternalError.new(sprintf('specified Vagrantfile [%s] does not exist', @vagrantfile))
    end

    @log.debug('instantiating Vagrant::Environment')
    @_env = Vagrant::Environment.new({:vagrantfile_name => @vagrantfile})

    @log.debug('loading Vagrantfile configuration')
    @_config = @_env.load_config!

    raise InternalError.new(sprintf('specified VM name [%s] not found in specified Vagrantfile', @name)) unless @_config.for_vm(@name.to_sym)

    @_vm_config = @_config.for_vm(@name.to_sym)
    @_vm_config.vm.base_mac = generate_unique_mac() # TODO need to take potential Vagrantfile modifications here

    @log.debug('instantiating Vagrant::VM')
    @_vm = Vagrant::VM.new(@name, @_env, @_vm_config)

    # no key is specified
    if @sshkey.nil?
      if @passthrough.eql?(true)
        raise InternalError.new('must specify sshkey when using a passthrough host')
      else
        # ask Vagrant where the key is
        @sshkey = @_env.default_private_key_path
      end
    end

    # confirm found/specified key exists
    if @sshkey.nil? or @_vm.ssh.check_key_permissions(@sshkey)
      raise InternalError.new("specified key [#{@sshkey}] does not exist/has bad permissions")
    end

    @log.debug('Rouster object successfully instantiated')

    # TODO should we open the SSH tunnel during instantiation as part of validity test?
    # only if it is optional and specified in parameters
  end

  def inspect
    "name [#{@name}]:
      created[#{@_vm.created?}],
      passthrough[#{@passthrough}],
      sshkey[#{@sshkey}],
      status[#{self.status()}]
      sudo[#{@sudo}],
      vagrantfile[#{@vagrantfile}],
      verbosity[#{verbosity}],
      Vagrant Environment object[#{@_env.class}],
      Vagrant Configuration object[#{@_config.class}],
      Vagrant VM object[#{@_vm.class}]\n"
  end

  ## Vagrant methods
  def up
    @log.info('up()')
    @_vm.channel.destroy_ssh_connection()

    # TODO need to dig deeper into this one -- issue #21
    if @_vm.created?
      self._run(sprintf('cd %s; vagrant up %s', File.dirname(@vagrantfile), @name))
    else
      @_vm.up
    end

    ## if the VM hasn't been created yet, we don't know the port
    @_config.for_vm(@name.to_sym).keys[:vm].forwarded_ports.each do |f|
      if f[:name].eql?('ssh')
        self.sshinfo[:port] = f[:hostport]
      end
    end

  end

  def destroy
    @log.info('destroy()')
    @_vm.destroy
  end

  def status
    @_vm.state.to_s
  end

  def suspend
    @log.info('suspend()')
    @_vm.suspend
  end

  ## internal methods
  def run(command)
    # runs a command inside the Vagrant VM
    output = nil

    @log.info(sprintf('vm running: [%s]', command))

    # TODO use a lambda here instead
    if self.uses_sudo?
      @exitcode = @_vm.channel.sudo(command, { :error_check => false } ) do |type,data|
        output ||= ""
        output += data
      end
    else
      @exitcode = @_vm.channel.execute(command, { :error_check => false } ) do |type,data|
        output ||= "" # don't like this, but borrowed from Vagrant, so feel less bad about it
        output += data
      end
    end

    unless @exitcode.eql?(0)
      raise RemoteExecutionError.new("output[#{output}], exitcode[#{@exitcode}]")
    end

    @exitcode ||= 0
    self.output.push(output)
    output
  end

  def is_available_via_ssh?
    # functional test to see if Vagrant machine can be logged into via ssh
    @_vm.channel.ready?()
  end

  def get(remote_file, local_file=nil)
    local_file = local_file.nil? ? File.basename(remote_file) : local_file
    @log.debug(sprintf('scp from VM[%s] to host[%s]', remote_file, local_file))

    raise SSHConnectionError.new(sprintf('unable to get[%s], SSH connection unavailable', remote_file)) unless self.is_available_via_ssh?

    begin
      @_vm.channel.download(remote_file, local_file)
    rescue => e
      raise SSHConnectionError.new(sprintf('unable to get[%s], exception[%s]', remote_file, e.message()))
    end

  end

  def put(local_file, remote_file=nil)
    remote_file = remote_file.nil? ? File.basename(local_file) : remote_file
    @log.debug(sprintf('scp from host[%s] to VM[%s]', local_file, remote_file))

    raise FileTransferError.new(sprintf('unable to put[%s], local file does not exist', local_file)) unless File.file?(local_file)
    raise SSHConnectionError.new(sprintf('unable to put[%s], SSH connection unavailable', remote_file)) unless self.is_available_via_ssh?

    begin
      @_vm.channel.upload(local_file, remote_file)
    rescue => e
      raise SSHConnectionError.new(sprintf('unable to put[%s], exception[%s]', local_file, e.message()))
    end

  end

  # there has _got_ to be a more rubyish way to do this
  def is_passthrough?
    self.passthrough.eql?(true)
  end

  def uses_sudo?
    # convenience method for the @sudo attribute
     self.sudo.eql?(true)
  end

  def rebuild
    # destroys/reups a Vagrant machine
    @log.debug('rebuild()')
    @_vm.destroy
    @_vm.up
  end

  def restart
    @log.debug('restart()')
    # restarts a Vagrant machine, wait time is same as rebuild()
    # how do we do this in a generic way? shutdown -rf works for Unix, but not Solaris
    #   we can ask Vagrant what kind of machine this is, but how far down this hole do we really want to go?

    # MVP
    self.run('/sbin/shutdown -rf now')

    # TODO implement some 'darwin award' checks in case someone tries to reboot a local passthrough?

  end

  def _run(command)
    # shells out and executes a command locally on the system, different than run(), which operates in the VM
    # returns STDOUT|STDERR, raises Rouster::LocalExecutionError on non 0 exit code

    tmp_file = sprintf('/tmp/rouster.%s.%s', Time.now.to_i, $$)
    cmd      = sprintf('%s > %s 2> %s', command, tmp_file, tmp_file)
    res      = `#{cmd}` # what does this actually hold?

    @log.info(sprintf('host running: [%s]', cmd))

    output = File.read(tmp_file)
    File.delete(tmp_file) or raise InternalError.new(sprintf('unable to delete [%s]: %s', tmp_file, $!))

    unless $?.success?
      raise LocalExecutionError.new(sprintf('command [%s] exited with code [%s], output [%s]', cmd, $?.to_i(), output))
    end

    self.output.push(output)
    @exitcode = $?.to_i()
    output
  end

  # truly internal methods
  def get_output(index = 0)
    # return index'th array of output in LIFO order

    # TODO do this in a mathy way instead of a youre-going-to-run-out-of-memory-way
    reversed = self.output.reverse
    reversed[index]
  end

  private

  def generate_unique_mac
    # ht http://www.commandlinefu.com/commands/view/7242/generate-random-valid-mac-addresses
    (1..6).map{"%0.2X" % rand(256)}.join('') # causes a fatal error with VboxManage if colons are left in
  end

  def traverse_up(startdir=Dir.pwd, filename=nil, levels=10)
    raise InternalError.new('must specify a filename') if filename.nil?

    @log.debug(sprintf('traverse_up() looking for [%s] in [%s], up to [%s] levels', filename, startdir, levels)) unless @log.nil?

    dirs  = startdir.split('/')
    count = 0

    while count < levels and ! dirs.nil?

      potential = sprintf('%s/Vagrantfile', dirs.join('/'))

      if File.file?(potential)
        return potential
      end

      dirs.pop()
      count += 1
    end
  end


end

# convenience truthiness methods
class Object
  def false?
    self.eql?(false)
  end

  def true?
    self.eql?(true)
  end
end
