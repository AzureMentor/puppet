require 'spec_helper'

require 'puppet/util/pidlock'

describe Puppet::Util::Pidlock, if: !Puppet::Util::Platform.jruby? do
  require 'puppet_spec/files'
  include PuppetSpec::Files

  before(:each) do
    @lockfile = tmpfile("lock")
    @lock = Puppet::Util::Pidlock.new(@lockfile)
  end

  describe "#lock" do
    it "should not be locked at start" do
      expect(@lock).not_to be_locked
    end

    it "should not be mine at start" do
      expect(@lock).not_to be_mine
    end

    it "should become locked" do
      @lock.lock
      if Puppet::Util::Platform.windows?
        allow(Puppet::Util::Windows::Process).to receive(:get_process_image_name_by_pid).with(@lock.lock_pid).and_return('C:\Program Files\Puppet Labs\Puppet\puppet\bin\ruby.exe')
      else
        allow(Puppet::Util::Execution).to receive(:execute).with(['ps', '-p', @lock.lock_pid, '-o', 'comm=']).and_return('puppet')
      end
      expect(@lock).to be_locked
    end

    it "should become mine" do
      @lock.lock
      expect(@lock).to be_mine
    end

    it "should be possible to lock multiple times" do
      @lock.lock
      expect { @lock.lock }.not_to raise_error
    end

    it "should return true when locking" do
      expect(@lock.lock).to be_truthy
    end

    it "should return true if locked by me" do
      @lock.lock
      expect(@lock.lock).to be_truthy
    end

    it "should create a lock file" do
      @lock.lock
      expect(Puppet::FileSystem.exist?(@lockfile)).to be_truthy
    end

    it 'should create an empty lock file even when pid is missing' do
      allow(Process).to receive(:pid).and_return('')
      @lock.lock
      expect(Puppet::FileSystem.exist?(@lock.file_path)).to be_truthy
      expect(Puppet::FileSystem.read(@lock.file_path)).to be_empty
    end

    it 'should replace an existing empty lockfile with a pid, given a subsequent lock call made against a valid pid' do
      # empty pid results in empty lockfile
      allow(Process).to receive(:pid).and_return('')
      @lock.lock
      expect(Puppet::FileSystem.exist?(@lock.file_path)).to be_truthy

      # next lock call with valid pid kills existing empty lockfile
      allow(Process).to receive(:pid).and_return(1234)
      @lock.lock
      expect(Puppet::FileSystem.exist?(@lock.file_path)).to be_truthy
      expect(Puppet::FileSystem.read(@lock.file_path)).to eq('1234')
    end

    it "should expose the lock file_path" do
      expect(@lock.file_path).to eq(@lockfile)
    end
  end

  describe "#unlock" do
    it "should not be locked anymore" do
      @lock.lock
      @lock.unlock
      expect(@lock).not_to be_locked
    end

    it "should return false if not locked" do
      expect(@lock.unlock).to be_falsey
    end

    it "should return true if properly unlocked" do
      @lock.lock
      expect(@lock.unlock).to be_truthy
    end

    it "should get rid of the lock file" do
      @lock.lock
      @lock.unlock
      expect(Puppet::FileSystem.exist?(@lockfile)).to be_falsey
    end
  end

  describe "#locked?" do
    it "should return true if locked" do
      @lock.lock
      if Puppet::Util::Platform.windows?
        allow(Puppet::Util::Windows::Process).to receive(:get_process_image_name_by_pid).with(@lock.lock_pid).and_return('C:\Program Files\Puppet Labs\Puppet\puppet\bin\ruby.exe')
      else
        allow(Puppet::Util::Execution).to receive(:execute).with(['ps', '-p', @lock.lock_pid, '-o', 'comm=']).and_return('puppet')
      end
      expect(@lock).to be_locked
    end

    it "should remove the lockfile when pid is missing" do
      allow(Process).to receive(:pid).and_return('')
      @lock.lock
      expect(@lock.locked?).to be_falsey
      expect(Puppet::FileSystem.exist?(@lock.file_path)).to be_falsey
    end
  end

  describe '#lock_pid' do
    it 'should return nil if the pid is empty' do
      # fake pid to get empty lockfile
      allow(Process).to receive(:pid).and_return('')
      @lock.lock
      expect(@lock.lock_pid).to eq(nil)
    end
  end

  describe "with a stale lock" do
    before(:each) do
      # fake our pid to be 1234
      allow(Process).to receive(:pid).and_return(1234)
      # lock the file
      @lock.lock
      # fake our pid to be a different pid, to simulate someone else
      #  holding the lock
      allow(Process).to receive(:pid).and_return(6789)

      allow(Process).to receive(:kill).with(0, 6789)
      allow(Process).to receive(:kill).with(0, 1234).and_raise(Errno::ESRCH)
    end

    it "should not be locked" do
      expect(@lock).not_to be_locked
    end

    describe "#lock" do
      it "should clear stale locks" do
        expect(@lock.locked?).to be_falsey
        expect(Puppet::FileSystem.exist?(@lockfile)).to be_falsey
      end

      it "should replace with new locks" do
        if Puppet::Util::Platform.windows?
          allow(Puppet::Util::Windows::Process).to receive(:get_process_image_name_by_pid).with(6789).and_return('C:\Program Files\Puppet Labs\Puppet\puppet\bin\ruby.exe')
        else
          allow(Puppet::Util::Execution).to receive(:execute).with(['ps', '-p', 6789, '-o', 'comm=']).and_return('puppet')
        end
        @lock.lock
        expect(Puppet::FileSystem.exist?(@lockfile)).to be_truthy
        expect(@lock.lock_pid).to eq(6789)
        expect(@lock).to be_mine
        expect(@lock).to be_locked
      end
    end

    describe "#unlock" do
      it "should not be allowed" do
        expect(@lock.unlock).to be_falsey
      end

      it "should not remove the lock file" do
        @lock.unlock
        expect(Puppet::FileSystem.exist?(@lockfile)).to be_truthy
      end
    end
  end

  describe "with another process lock" do
    before(:each) do
      # fake our pid to be 1234
      allow(Process).to receive(:pid).and_return(1234)
      if Puppet::Util::Platform.windows?
        allow(Puppet::Util::Windows::Process).to receive(:get_process_image_name_by_pid).with(1234).and_return('C:\Program Files\Puppet Labs\Puppet\puppet\bin\ruby.exe')
      else
        allow(Puppet::Util::Execution).to receive(:execute).with(['ps', '-p', 1234, '-o', 'comm=']).and_return('puppet')
      end
      # lock the file
      @lock.lock
      # fake our pid to be a different pid, to simulate someone else
      #  holding the lock
      allow(Process).to receive(:pid).and_return(6789)

      allow(Process).to receive(:kill).with(0, 6789)
      allow(Process).to receive(:kill).with(0, 1234)
    end

    it "should be locked" do
      expect(@lock).to be_locked
    end

    it "should not be mine" do
      expect(@lock).not_to be_mine
    end

    describe "#lock" do
      it "should not be possible" do
        expect(@lock.lock).to be_falsey
      end

      it "should not overwrite the lock" do
        @lock.lock
        expect(@lock).not_to be_mine
      end
    end

    describe "#unlock" do
      it "should not be possible" do
        expect(@lock.unlock).to be_falsey
      end

      it "should not remove the lock file" do
        @lock.unlock
        expect(Puppet::FileSystem.exist?(@lockfile)).to be_truthy
      end

      it "should still not be our lock" do
        @lock.unlock
        expect(@lock).not_to be_mine
      end
    end
  end
end
